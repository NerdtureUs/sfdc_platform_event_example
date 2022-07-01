class Retryable # we define a class to handle retrying web callouts. If the callout fails (e.g. time out) we wait 2 seconds and try again, up to the value.
	class << self
		def retryable(options = {})
			# when calling this method, optionally pass the number of tries you want to support, and the type of exception to handle
			# e.g.
			# retryable(tries: 3, on: Timeout::Error) do
			#   response = HTTParty.post(uri,body: body, headers: TOKEN_HEADERS)
			# END
			#
			# this will try to post a request to the designated url, with the provide body and headers
			# it will retry 3 times and raises the encountered exception
			opts = { tries: 1, on: Exception }.merge(options)
			retry_exception, retries = opts[:on], opts[:tries]
			begin
				return yield
			rescue retry_exception # you can create specific handling for various types of exceptions, but in this case I simply am handling the Exception which was passed in
				if (retries -= 1) >0 # decrement the retries value by 1, and if we are still greater than 0, sleep and retry
					sleep 2
					retry # this is the native ruby function to re process the block which failed.
				else # Retries value got to 0, so we give up
					raise
				end
			end
		end
	end
end