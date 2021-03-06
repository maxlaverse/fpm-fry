require 'excon/middlewares/base'
module FPM; module Fry
  class StreamParser

    class ShortRead < EOFError
    end

    class Instance < Excon::Middleware::Base

      def initialize(stack, parser)
        super(stack)
        @parser = parser
      end

      def response_call(datum)
        if datum[:response]
          # probably mocked
          if datum[:response][:body]
            @parser.parse(StringIO.new(datum[:response][:body]))
          end
          return @stack.response_call(datum)
        else
          socket = datum[:connection].send(:socket)
          begin
            line = socket.readline
            match = /^HTTP\/\d+\.\d+\s(\d{3})\s/.match(line)
          end while !match
          status = match[1].to_i

          datum[:response] = {
            :body          => '',
            :headers       => Excon::Headers.new,
            :status        => status,
            :remote_ip     => socket.respond_to?(:remote_ip) && socket.remote_ip,
          }
          Excon::Response.parse_headers(socket, datum)

          @parser.parse(socket)
          return @stack.response_call(datum)
        end
      end

    end

    attr :out, :err

    def initialize(out, err)
      @out, @err = out, err
      @state = :null
      @left = 0
    end

    def new(stack)
      Instance.new(stack, self)
    end

    def parse(socket)
      left  = 0
      streams = {1 => out, 2 => err}
      loop do
        type = read_exactly(socket,4){|part|
          if part.bytesize == 0
            return
          else
            raise ShortRead
          end
        }.unpack("c".freeze)[0]
        stream = streams.fetch(type){ raise ArgumentError, "Wrong stream type: #{type}"}
        len  = read_exactly(socket,4).unpack('I>')[0]
        while len > 0
          chunk = socket.read([64,len].min)
          raise ShortRead if chunk.nil?
          len -= chunk.bytesize
          stream.write(chunk)
        end
      end
    end

    def read_exactly(socket, len)
      buf = ""
      left = len
      while left != 0
        read = socket.read(left)
        if read.nil?
          if block_given?
            yield buf
          else
            raise ShortRead
          end
        end
        buf << read
        left = len - buf.bytesize
      end
      return buf
    end

  end
end ; end
