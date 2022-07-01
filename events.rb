require 'faye'
require 'eventmachine'
EM.run do # Use EventMachine to open a process that will stay open until we shut it down.
	# Call the handler that subscribes to the Address_Request__e Platform event
	MySfdc.listen_to_addresses
	# If you wanted to listen to multiple platform events, you can additional listeners

	# the following is for example only, and isn't in the code i've provided
	#MySfdc.listen_to_customers
end
