# =XMPP4R - XMPP Library for Ruby
# License:: Ruby's license (see the LICENSE file) or GNU GPL, at your option.
# Website::http://home.gna.org/xmpp4r/

require 'digest/md5'
require 'xmpp4r/base64'

module Jabber
  ##
  # Helpers for SASL authentication (RFC2222)
  #
  # You might not need to use them directly, they are
  # invoked by Jabber::Client#auth
  module SASL
    NS_SASL = 'urn:ietf:params:xml:ns:xmpp-sasl'

    ##
    # Factory function to obtain a SASL helper for the specified mechanism
    def SASL.new(stream, mechanism)
      case mechanism
        when 'SCRAM-SHA-1'
          SCRAMSHA1.new(stream)
        when 'DIGEST-MD5'
          DigestMD5.new(stream)
        when 'PLAIN'
          Plain.new(stream)
        when 'ANONYMOUS'
          Anonymous.new(stream)
        else
          raise "Unknown SASL mechanism: #{mechanism}"
      end
    end

    ##
    # SASL mechanism base class (stub)
    class Base
      def initialize(stream)
        @stream = stream
      end

      private

      def generate_auth(mechanism, text=nil)
        auth = REXML::Element.new 'auth'
        auth.add_namespace NS_SASL
        auth.attributes['mechanism'] = mechanism
        auth.text = text
        auth
      end

      def generate_nonce
        Digest::MD5.hexdigest(Time.new.to_f.to_s)
      end
    end

    ##
    # SASL PLAIN authentication helper (RFC2595)
    class Plain < Base
      ##
      # Authenticate via sending password in clear-text
      def auth(password)
        auth_text = "#{@stream.jid.strip}\x00#{@stream.jid.node}\x00#{password}"
        error = nil
        @stream.send(generate_auth('PLAIN', Base64::encode64(auth_text).gsub(/\s/, ''))) { |reply|
          if reply.name != 'success'
            error = reply.first_element(nil).name
          end
          true
        }

        raise error if error
      end
    end

    ##
    # SASL Anonymous authentication helper
    class Anonymous < Base
      ##
      # Authenticate by sending nothing with the ANONYMOUS token
      def auth(password)
        auth_text = "#{@stream.jid.node}"
        error = nil
        @stream.send(generate_auth('ANONYMOUS', Base64::encode64(auth_text).gsub(/\s/, ''))) { |reply|
          if reply.name != 'success'
            error = reply.first_element(nil).name
          end
          true
        }

        raise error if error
      end
    end

    ##
    # SASL DIGEST-MD5 authentication helper (RFC2831)
    class DigestMD5 < Base
      ##
      # Sends the wished auth mechanism and wait for a challenge
      #
      # (proceed with DigestMD5#auth)
      def initialize(stream)
        super

        challenge = {}
        error = nil
        @stream.send(generate_auth('DIGEST-MD5')) { |reply|
          if reply.name == 'challenge' and reply.namespace == NS_SASL
            challenge = decode_challenge(reply.text)
          else
            error = reply.first_element(nil).name
          end
          true
        }
        raise error if error

        @nonce = challenge['nonce']
        @realm = challenge['realm']
      end

      def decode_challenge(challenge)
        text = Base64::decode64(challenge)
        res = {}

        state = :key
        key = ''
        value = ''
        text.scan(/./) do |ch|
          if state == :key
            if ch == '='
              state = :value
            else
              key += ch
            end

          elsif state == :value
            if ch == ','
              # due to our home-made parsing of the challenge, the key could have
              # leading whitespace. strip it, or that would break jabberd2 support.
              key = key.strip
              res[key] = value
              key = ''
              value = ''
              state = :key
            elsif ch == '"' and value == ''
              state = :quote
            else
              value += ch
            end

          elsif state == :quote
            if ch == '"'
              state = :value
            else
              value += ch
            end
          end
        end
        # due to our home-made parsing of the challenge, the key could have
        # leading whitespace. strip it, or that would break jabberd2 support.
        key = key.strip
        res[key] = value unless key == ''

        Jabber::debuglog("SASL DIGEST-MD5 challenge:\n#{text}\n#{res.inspect}")

        res
      end

      ##
      # * Send a response
      # * Wait for the server's challenge (which aren't checked)
      # * Send a blind response to the server's challenge
      def auth(password)
        response = {}
        response['nonce'] = @nonce
        response['charset'] = 'utf-8'
        response['username'] = @stream.jid.node
        response['realm'] = @realm || @stream.jid.domain
        response['cnonce'] = generate_nonce
        response['nc'] = '00000001'
        response['qop'] = 'auth'
        response['digest-uri'] = "xmpp/#{@stream.jid.domain}"
        response['response'] = response_value(@stream.jid.node, response['realm'], response['digest-uri'], password, @nonce, response['cnonce'], response['qop'], response['authzid'])
        response.each { |key,value|
          unless %w(nc qop response charset).include? key
            response[key] = "\"#{value}\""
          end
        }

        response_text = response.collect { |k,v| "#{k}=#{v}" }.join(',')
        Jabber::debuglog("SASL DIGEST-MD5 response:\n#{response_text}\n#{response.inspect}")

        r = REXML::Element.new('response')
        r.add_namespace NS_SASL
        r.text = Base64::encode64(response_text).gsub(/\s/, '')

        success_already = false
        error = nil
        # This send hangs sometimes waiting in Stream#send on threadblock.wait (with Openfire 3.6.4 at least);
        #  since the calback here is pretty simple, that likely means it never receives a response stanza
        #  therefore we should put in a timeout on send, and do some retries here (okay since its the first message)
        # TODO Verify if 1 second timeout, and 3 tries are good settings
        # TODO Add test/spec when/if they are created
        tries = 3
        begin
          @stream.send(r, 1) { |reply|
            if reply.name == 'success'
              success_already = true
            elsif reply.name != 'challenge'
              error = reply.first_element(nil).name
            end
            true
          }
        rescue Timeout::Error
          retry if (tries -= 1) > 0
          # TODO create a SASL::AuthError to handle this and other direct raise calls
          raise "Failed to send SASL::DigestMD5 response"
        end

        return if success_already
        raise error if error

        # TODO: check the challenge from the server

        r.text = nil
        @stream.send(r) { |reply|
          if reply.name != 'success'
            error = reply.first_element(nil).name
          end
          true
        }

        raise error if error
      end

      private

      ##
      # Function from RFC2831
      def h(s); Digest::MD5.digest(s); end
      ##
      # Function from RFC2831
      def hh(s); Digest::MD5.hexdigest(s); end

      ##
      # Calculate the value for the response field
      def response_value(username, realm, digest_uri, passwd, nonce, cnonce, qop, authzid)
        a1_h = h("#{username}:#{realm}:#{passwd}")
        a1 = "#{a1_h}:#{nonce}:#{cnonce}"
        if authzid
          a1 += ":#{authzid}"
        end
        if qop == 'auth-int' || qop == 'auth-conf'
          a2 = "AUTHENTICATE:#{digest_uri}:00000000000000000000000000000000"
        else
          a2 = "AUTHENTICATE:#{digest_uri}"
        end
        hh("#{hh(a1)}:#{nonce}:00000001:#{cnonce}:#{qop}:#{hh(a2)}")
      end
    end

    ##
    # SASL SCRAM-SHA1 authentication helper
    class SCRAMSHA1 < Base
      ##
      # Sends the wished auth mechanism and wait for a challenge
      #
      # (proceed with SCRAMSHA1#auth)
      def initialize(stream)
        super

        @nonce = generate_nonce
        @client_fm = "n=#{escape @stream.jid.node },r=#{@nonce}"

        challenge = {}
        challenge_text = ''
        error = nil
        @stream.send(generate_auth('SCRAM-SHA-1', text=Base64::strict_encode64('n,,'+@client_fm))) { |reply|
          if reply.name == 'challenge' and reply.namespace == NS_SASL
            challenge_text = Base64::decode64(reply.text)
            challenge = decode_challenge(challenge_text)
          else
            error = reply.first_element(nil).name
          end
          true
        }
        raise error if error

        @server_fm = challenge_text
        @cnonce = challenge['r']
        @salt = Base64::decode64(challenge['s'])
        @iterations = challenge['i'].to_i

        raise 'SCRAM-SHA-1 protocol error' if @cnonce[0, @nonce.length] != @nonce
      end

      def decode_challenge(text)
        res = {}

        state = :key
        key = ''
        value = ''
        text.scan(/./) do |ch|
          if state == :key
            if ch == '='
              state = :value
            else
              key += ch
            end

          elsif state == :value
            if ch == ','
              # due to our home-made parsing of the challenge, the key could have
              # leading whitespace. strip it, or that would break jabberd2 support.
              key = key.strip
              res[key] = value
              key = ''
              value = ''
              state = :key
            elsif ch == '"' and value == ''
              state = :quote
            else
              value += ch
            end

          elsif state == :quote
            if ch == '"'
              state = :value
            else
              value += ch
            end
          end
        end
        # due to our home-made parsing of the challenge, the key could have
        # leading whitespace. strip it, or that would break jabberd2 support.
        key = key.strip
        res[key] = value unless key == ''

        Jabber::debuglog("SASL SCRAM-SHA-1 challenge:\n#{text}\n#{res.inspect}")

        res
      end

      ##
      # * Send a response
      # * Wait for the server's challenge (which aren't checked)
      # * Send a blind response to the server's challenge
      def auth(password)
        salted_password = hi(password, @salt, @iterations)
        client_key = hmac(salted_password, 'Client Key')
        stored_key = h(client_key)

        final_message = "c=#{Base64::strict_encode64('n,,')},r=#{@cnonce}"
        auth_message = "#{@client_fm},#{@server_fm},#{final_message}"

        client_signature = hmac(stored_key, auth_message)
        client_proof = xor(client_key, client_signature)


        response_text = "#{final_message},p=#{Base64::strict_encode64(client_proof)}"

        Jabber::debuglog("SASL SCRAM-SHA-1 response:\n#{response_text}")

        r = REXML::Element.new('response')
        r.add_namespace NS_SASL
        r.text = Base64::strict_encode64(response_text)

        error = nil
        success = {}
        @stream.send(r) { |reply|
          if reply.name == 'success' and reply.namespace == NS_SASL
            success = decode_challenge(Base64::decode64(reply.text))
          elsif reply.name != 'challenge'
            error = reply.first_element(nil).name
          end
          true
        }

        raise error if error

        server_key = hmac(salted_password, 'Server Key')
        server_signature = hmac(server_key, auth_message)

        raise "Server authentication failed" if Base64::decode64(success['v']) != server_signature
      end

      private

      def xor(a, b)
        a.unpack('C*').zip(b.unpack('C*')).collect { | x, y | x ^ y }.pack('C*')
      end

      def h(s)
        Digest::SHA1.digest(s)
      end

      def hmac(key, s)
        OpenSSL::HMAC.digest('sha1', key, s)
      end

      def hi(s, salt, i)
        r = Array.new(size=20, obj=0).pack('C*')
        u = salt + [0, 0, 0, 1].pack('C*')

        i.times do |x|
          u = hmac(s, u)
          r = xor(r, u)
        end

        r
      end

      def escape(data)
        data.gsub(/=/, '=3D').gsub(/,/, '=2C')
      end
    end
  end
end
