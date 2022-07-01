# This exmple is one I wrote for a customer of mine, and demonstrates
# * connecting to salesfore using a Connected App
# * Subscribing to a Platform event named Address_Request__e
# * Publishing to a platform event named Address_Request__e
#
# This is working code before I added the comments to explain how it works.
# If you run into problems having it run, remove my comments first, incase I broke it by adding documentation
#

require 'httparty' # We use httparty to simplify calling out to external systems. It handles much of the repatitive code that is typicall needed
class MySfdc < Retryable # we inherit from the Retryable class, so we can use the retryable method

	# this was written for a rails application, but you can as easly store this in an environment variable, or even hard code the values (not recommended)
	# adjust these variables for your environment
	SALESFORCE_USERNAME=Rails.application.config.sfdc_username # Set the Authenticating User
	SALESFORCE_PASSWORD=Rails.application.config.sfdc_password
	SALESFORCE_CLIENT_ID=Rails.application.config.sfdc_client_id # specify the Connected App to connect through
	SALESFORCE_CLIENT_SECRET=Rails.application.config.sfdc_client_secret
	SALESFORCE_API_VERSION=Rails.application.config.sfdc_api_version # Set the Salesforce API version you want to use
	SALESFORCE_HOST=Rails.application.config.sfdc_host # This is typically login.salesforce.com or test.salesforce.com, but it can be a customer specific domain
	SYSTEM_SOURCE=Rails.application.config.system_source # Because you may be a consumer and a subscriber, it is good to specify the source system, so you can ensure you don't try to process your own events
	TOKEN_HEADERS={"X-PrettyPrint": "1"} # Optionally format the returned value to be indented and split into separate rows to be more human friendly

	@@ACCESS_TOKEN = nil # Start with a blank Access_token
	private_constant :SYSTEM_SOURCE,:SALESFORCE_USERNAME,:SALESFORCE_PASSWORD,:SALESFORCE_CLIENT_ID,:SALESFORCE_CLIENT_SECRET,:SALESFORCE_API_VERSION # to prevent leaking secure information, ensure these constent variables are private, so they cannot be accessed outside of this class
	mattr_accessor :token_expire_time, :instance_url # create accessors so the class can access these variables

	class << self

		# Connect to salesforce, authenticate, and store the instance url, token expire time, and Access Token
		def get_token
			if @@token_expire_time.nil? || @@token_expire_time > Time.now + 60 * 2 # I like to refresh my tokens early, so this refreshes this will re authenticate if the token expires in the next 2 minutes, you need to allow for your max retry length in this, or your retry may fail because your token has expired.
				p "Getting a new Token Expire Time: #{@@token_expire_time} Now: #{Time.now}"
				uri = "https://#{SALESFORCE_HOST}/services/oauth2/token"
				# required body values for salesforce authentication
				body = {
					grant_type:'password',
					client_id: SALESFORCE_CLIENT_ID,
					client_secret: SALESFORCE_CLIENT_SECRET,
					username: SALESFORCE_USERNAME,
					password: SALESFORCE_PASSWORD
				}

				response = nil
				# Attempt to authenticate with salesforce, retry up to 3 times if the connection times out
				retryable(tries: 3, on: Timeout::Error) do
					p 'posting request'
					response = HTTParty.post(uri,body: body, headers: TOKEN_HEADERS)
				end
				p "Response code: #{response.code} body: #{response.body}" unless response.code == 200
				# If we authenticated successfully, set the class variables from the respons
				if response.code == 200
					begin
						res = JSON.parse(response.body)
						@@ACCESS_TOKEN = res["access_token"]
						@@token_expire_time = Time.now + 120
						@@instance_url = res["instance_url"]
					rescue JSON::ParserError => e
						p "INVALID JSON: #{e.message}"
					end
				end
				response.code == 200
			else
				true
			end
		end

		# this methods publishes a message on the address platform event. This will retry up to 4 times to publish before it quits
		def send_address(address, count=0)
			if get_token && count <= 4 # Ensure we have a valid authorization token, and we are within 4 retries.
				uri = "#{@@instance_url}/services/data/v#{SALESFORCE_API_VERSION}/sobjects/Address_Request__e/" # this is the actual Plaform event queue
				body = address_to_address_request(address) # Passin our address object and receive back the JSON object for the platform even
				headers = {Authorization: "Bearer #{@@ACCESS_TOKEN}", "Content-Type":"application/json"}
				response = nil
				retryable(tries: 3, on: Timeout::Error) do
					response = HTTParty.post(uri,body: body.to_json, headers: headers)
				end
				p response.body
				# bad responses come back as 401 codes. If we receive a 401 error, we retry the call
				if response.code == 401
					p "send_address: Retrying address #{address.to_json.to_s}"
					@@token_expire_time = nil # The most common reason i've seen for a 401 was the token expired, so we set it to blank so we get a new token the next time we try to call out
					send_address(address, count + 1) # call the same function, but increase the count by 1
				elsif response.code >= 200 && response.code <= 299 # you can receive many different responses from salesforce, so any 2xx response is a good response and we can move on
					p "send_address: Success #{address.id} : #{address.ship_name} : #{response.body}"
					return true
				end
				p "Response Code: #{response.code} : Body: #{response.body}"
				false
			else
				p "send_address: Count Exceeded for Address #{address.to_json.to_s}"
			end
		end
		# this method listens to the address platform events
		def listen_to_addresses
			p "Listening to addresses"
			EM.run do # EventMachine is an event-driven I/O and lightweight concurrency library for Ruby. See https://github.com/eventmachine/eventmachine
				# Call the subscription method to establish a faye connection listening to our address platform event
				subscription '/event/Address_Request__e', replay: -2 do |message|
					p "Address: #{message}"
					p message
				end
			end
		end
		private
		# private class method for subscribing to events (aka channels)
		def subscription(channels, options = {}, &block)
			one_or_more_channels = Array(channels)
			one_or_more_channels.each do |channel|
				replay_handlers[channel] = options[:replay]
			end
			faye.subscribe(one_or_more_channels, &block)
		end
		# Salesforce's platform events (and Streaming API) utilize the Bayeux protocol and CometD routing bus. See https://developer.salesforce.com/docs/atlas.en-us.api_streaming.meta/api_streaming/BayeauxProtocolAndCometD.htm
		# faye is a ruby and node client for connecting to CometD services https://github.com/faye/faye
		# This method ensures we've authenticated and creates a Faye client to connect to the CometD routing bus
		def faye
			if get_token
				unless @@instance_url
					raise 'Instance URL missing. Call .authenticate! first.'
				end
				url = "#{@@instance_url}/cometd/#{SALESFORCE_API_VERSION}"
				@faye ||= Faye::Client.new(url).tap do |client|
					client.set_header 'Authorization', "Bearer #{@@ACCESS_TOKEN}"
					# This will be run when ever the connection goes down, and re-connects to the CometD bus
					client.bind 'transport:down' do
					  p "[COMETD DOWN]"
					  client.set_header 'Authorization', "Bearer #{@@ACCESS_TOKEN}"
					end
					# This simply logs that we are connected
					client.bind 'transport:up' do
						p "[COMETD UP]"
					end
					client.add_extension ReplayExtension.new(replay_handlers)
				end
			end
		end
		def replay_handlers
			@_replay_handlers ||= {}
		end
		# this Class creates the functions to work within the CometD bus, and builds the formats for posting to our platform events.
		class ReplayExtension
			def initialize(replay_handlers)
				@replay_handlers = replay_handlers
			end
			# Handle incoming messages by subsription channel. For each chanel we store the last replay_id
			def incoming(message, callback)
				callback.call(message).tap do
					channel = message.fetch('channel')
					replay_id = message.fetch('data', {}).fetch('event', {})['replayId']

					handler = @replay_handlers[channel]
					if !replay_id.nil? && !handler.nil? && handler.respond_to?(:[]=)
					# remember the last replay_id for this channel
					handler[channel] = replay_id
					end
				end
			end
			# Handler for outbound messages
			def outgoing(message, callback)
				# Leave non-subscribe messages alone
				return callback.call(message) unless message['channel'] == '/meta/subscribe'

				channel = message['subscription']

				# Set the replay value for the channel
				message['ext'] ||= {}
				message['ext']['replay'] = {
					channel => replay_id(channel)
				}

				# Carry on and send the message to the server
				callback.call message
			end

			private

			def replay_id(channel)
				handler = @replay_handlers[channel]
				if handler.is_a?(Integer)
					handler # treat it as a scalar
				elsif handler.respond_to?(:[])
					# Ask for the latest replayId for this channel
					handler[channel]
				else
					# Just pass it along
					handler
				end
			end
		end
		# for each platform event you need to define the fields and map them to the data you want to send
		# This is an example of an Address Platform event, which passes an address object in, and returns a JSON object with the correct values mapped for the Platform event's custom fields
		# Notice the Source__c field, this allows us to track which system the message is coming from
		def address_to_address_request(address)
			res = {
				"Source__c": SYSTEM_SOURCE,
				"Company__c": address.company,
				"First_Name__c": address.first_name,
				"Last_Name__c": address.last_name,
				"Email__c": address.email,
				"Phone__c": address.phone,
				"Address1__c": address.address1,
				"Address2__c": address.address2,
				"City__c": address.city,
				"State__c": address.state,
				"Postal_Code__c": address.postal_code,
				"Country__c": address.country
			}
		end
	end
end