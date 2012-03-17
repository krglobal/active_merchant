module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    
    class SecurePayGateway < Gateway

      class_inheritable_accessor :test_url, :live_url, :arb_test_url, :arb_live_url

      self.test_url = "https://www.securepay.com/secure1/index.asp"
      self.live_url = "https://www.securepay.com/secure1/index.asp"

      APPROVED, DECLINED, ERROR, FRAUD_REVIEW = 1, 2, 3, 4

      RESPONSE_CODE, RESPONSE_REASON_CODE, RESPONSE_REASON_TEXT = 0, 2, 3
      AVS_RESULT_CODE, TRANSACTION_ID, CARD_CODE_RESPONSE_CODE  = 5, 6, 38

      self.supported_countries = ['US']
      self.supported_cardtypes = [:visa, :master, :discover]
      self.homepage_url = 'http://www.securepay.net/'
      self.display_name = 'SecurePay'

      CARD_CODE_ERRORS = %w( N S )
      AVS_ERRORS = %w( A E N R W Z )

      AUTHORIZE_NET_ARB_NAMESPACE = 'AnetApi/xml/v1/schema/AnetApiSchema.xsd'

      RECURRING_ACTIONS = {
        :create => 'ARBCreateSubscription',
        :update => 'ARBUpdateSubscription',
        :cancel => 'ARBCancelSubscription'
      }

      # Creates a new SecurePay
      #
      # The gateway requires that a valid login and password be passed
      # in the +options+ hash.
      #
      # ==== Options
      #
      # * <tt>:login</tt> -- The Authorize.Net API Login ID (REQUIRED)
      # * <tt>:password</tt> -- The Authorize.Net Transaction Key. (REQUIRED)
      # * <tt>:test</tt> -- +true+ or +false+. If true, perform transactions against the test server. 
      #   Otherwise, perform transactions against the production server.
      def initialize(options = {})
        requires!(options, :login, :password)
        @options = options
        super
      end

      # Perform a purchase, which is essentially an authorization and capture in a single operation.
      #
      # ==== Parameters
      #
      # * <tt>money</tt> -- The amount to be purchased. Either an Integer value in cents or a Money object.
      # * <tt>creditcard</tt> -- The CreditCard details for the transaction.
      # * <tt>options</tt> -- A hash of optional parameters.
      def purchase(amount, creditcard, options = {})
        post = {}
        add_invoice(post, options)
        add_creditcard(post, creditcard)
        add_address(post, options)
        add_customer_data(post, options)
        add_recurring_data(post, options, amount) if options[:recurring_period]

        # DO AN AUTHORIZATION IN ORDER TO CHECK CARD AND ADDRESS
        sale_response = commit('SALE', amount, post)

        # if not approved, just return the response
        if !sale_response.success?
          return sale_response

        else
          # if test mode, just return response and skip AVS checking
          return sale_response if options[:test] == 'test'
          
          # if approved, also check the AVS response.   
          # if valid AVS return success, 
          if VALID_AVS_CODES.include?(sale_response.avs_result['code'])
            return sale_response
          else
            # else invalid AVS so void sale and return error message
            post[:voidrecnum] = sale_response.voidrecnum.strip
            void_response = commit('VOID', amount, post)
            
            # invalid AVS code so return with AVS message
            RAILS_DEFAULT_LOGGER.info sale_response.avs_result['message'].to_s
            message = "<span title='#{sale_response.avs_result['message'].to_s} '>Address does not match card.<br/>Please verify your card information.</span>"
            return Response.new(false, message,{},{:test => true}) 
          end
        end
      end

      # Void a previous transaction
      #
      # ==== Parameters
      #
      # * <tt>authorization</tt> - The authorization returned from the previous authorize request.
      def void(authorization, options = {})
        post = {:trans_id => authorization}
        commit('VOID', nil, post)
      end

      # Credit an account.
      #
      # This transaction is also referred to as a Refund and indicates to the gateway that
      # money should flow from the merchant to the customer.
      #
      # ==== Parameters
      #
      # * <tt>money</tt> -- The amount to be credited to the customer. Either an Integer value in cents or a Money object.
      # * <tt>identification</tt> -- The ID of the original transaction against which the credit is being issued.
      # * <tt>options</tt> -- A hash of parameters.
      #
      # ==== Options
      #
      # * <tt>:card_number</tt> -- The credit card number the credit is being issued to. (REQUIRED)
      def credit(money, identification, options = {})
        requires!(options, :card_number)

        post = { :trans_id => identification,
                 :card_num => options[:card_number]
               }
        add_invoice(post, options)

        commit('CREDIT', money, post)
      end


      private

      def commit(action, money, parameters)
        parameters[:amount] = amount(money) unless action == 'VOID'

        # Only activate the test_request when the :test option is passed in
        parameters[:test_request] = @options[:test] ? 'TRUE' : 'FALSE'

        url = test? ? self.test_url : self.live_url

        data = ssl_post url, post_data(action, parameters)

        response = parse(data)

        message = message_from(response)

        begin
          # output params less but only last 4 of cc number
          RAILS_DEFAULT_LOGGER.info "S.P. Post: " + post_data(action, parameters.merge(:cc_number => parameters[:cc_number].reverse[0,4].reverse)).split('&').join(', ')
        rescue
          RAILS_DEFAULT_LOGGER.info "**ERROR** S.P. Post: " + post_data(action, parameters).split('&').join(', ')
        end
        RAILS_DEFAULT_LOGGER.info "SP Response String: " + data
        RAILS_DEFAULT_LOGGER.info "SP Response: " + response.to_s

        # Return the response. The authorization can be taken out of the transaction_id
        # Test Mode on/off is something we have to parse from the response text.
        # It usually looks something like this
        #
        #   (TESTMODE) Successful Sale
        test_mode = test? || message =~ /TESTMODE/

        Response.new(success?(response), message, response, 
          :test => test_mode, 
          :authorization => response[:transaction_id],
          :fraud_review => fraud_review?(response),
          :avs_result => { :code => response[:avs_result_code] },
          :voidrecnum => response[:voidrecnum].to_s.strip
        )
      end

      def success?(response)
        response[:response_code] == APPROVED
      end

      def fraud_review?(response)
        response[:response_code] == FRAUD_REVIEW
      end

      def parse(data)

        fields = data.split(',')

        results = {
          :response_code => (fields[0] == "N" ? 0 : 1),
          :transaction_id => fields[1],
          :response_reason_text => fields[2],
          :avs_result_code => fields[3],
          :voidrecnum => fields[4]
        }
        results
      end

      def post_data(action, parameters = {})
        post = {}
        post[:tr_type]        = action
        post[:merch_id]       = @options[:login]
        post[:transkey]       = @options[:password]
        post[:cc_method]      = 'DataEntry'
        post[:avsreq]         = '1'

        request = post.merge(parameters).collect { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }.join("&")
        request
      end

      def add_invoice(post, options)
        post[:comment1] = options[:order_id]
        post[:comment2] = options[:description]
      end

      def add_creditcard(post, creditcard)
        post[:cc_number]  = creditcard.number
        post[:cvv2]  = creditcard.verification_value if creditcard.verification_value?
        post[:year]       = creditcard.year.to_s[2,2]
        post[:month]      = sprintf("%.2i", creditcard.month)
        post[:name] = creditcard.first_name.to_s + ' ' + creditcard.last_name.to_s
      end

      def add_customer_data(post, options)
          post[:email] = options[:email]
      end

      def add_address(post, options)
        if address = options[:billing_address] || options[:address]
          post[:street] = address[:address1].to_s
          post[:zip]     = address[:zip].to_s
          post[:city]    = address[:city].to_s
          post[:state]   = address[:state]
        end
      end

      # add recurring data
      def add_recurring_data(post, options, money)
          post[:recurring] = 'Yes'
          post[:rec_amount] = amount(money)
          post[:timeframe] = options[:recurring_period].delete('ly')
      end

      # Make a ruby type out of the response string
      def normalize(field)
        case field
        when "true"   then true
        when "false"  then false
        when ""       then nil
        when "null"   then nil
        else field
        end
      end

      def message_from(results)
        # This code looks erroneous.  DECLINED = 2 but we use 0 as the declined value.  
        #  Only a value of 1 means success.   no other value does anything.
        if results[:response_code] == DECLINED
          return CVVResult.messages[ results[:card_code] ] if CARD_CODE_ERRORS.include?(results[:card_code])
          return AVSResult.messages[ results[:avs_result_code] ] if AVS_ERRORS.include?(results[:avs_result_code])
        end

        return results[:response_reason_text].nil? ? '' : results[:response_reason_text]
      end

    end

    AuthorizedNetGateway = AuthorizeNetGateway
  end
end
