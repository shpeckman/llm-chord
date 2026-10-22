# src/llm-chord/websocket.cr
require "http/web_socket"
require "http/server/handlers/websocket_handler"

module LLM::Chord
  class WebSocketLink < BaseLink
    @running = false

    def initialize(@socket : HTTP::WebSocket, @compress : Bool = false, @accept_packed : Bool = true, run : Bool = true)
      @socket.on_message { |text| on_text(text) }
      @socket.on_binary { |bytes| on_bytes(bytes) }
      @socket.on_close { ended("socket closed") }
      spawn { self.run } if run
    end

    def self.connect(uri : URI | String, headers : HTTP::Headers = HTTP::Headers.new, compress : Bool = false) : WebSocketLink
      new(HTTP::WebSocket.new(uri.is_a?(URI) ? uri : URI.parse(uri), headers), compress: compress)
    end

    def run : Nil
      return if @running
      @running = true
      begin
        @socket.run
      rescue IO::Error
      end
      ended("socket closed")
    end

    protected def transmit(frame : Frame) : Int32?
      data = Wire.encode_message(frame, @compress)
      begin
        @socket.send(data)
      rescue IO::Error
        spawn { ended("socket closed") }
      end
      data.bytesize
    end

    protected def shutdown : Nil
      @socket.close(HTTP::WebSocket::CloseCode::NormalClosure)
    rescue IO::Error
    end

    private def on_text(text : String) : Nil
      deliver(Wire.parse(text))
    rescue
      close("protocol error")
    end

    private def on_bytes(bytes : Bytes) : Nil
      raise ArgumentError.new("packed frames are not accepted") unless @accept_packed
      deliver(Wire.decode_message(bytes))
    rescue
      close("protocol error")
    end
  end

  def self.web_socket_link(socket : HTTP::WebSocket, compress : Bool = false, accept_packed : Bool = true,
                           run : Bool = true) : WebSocketLink
    WebSocketLink.new(socket, compress, accept_packed, run)
  end

  def self.accept_web_sockets(host : Host, **options, &principal : HTTP::Server::Context -> T) : HTTP::WebSocketHandler forall T
    web_socket_acceptor(host, LinkOptions.new(**options), principal)
  end

  private def self.web_socket_acceptor(host : Host, options : LinkOptions, principal : Proc(HTTP::Server::Context, T)) : HTTP::WebSocketHandler forall T
    HTTP::WebSocketHandler.new do |socket, context|
      link = WebSocketLink.new(socket, compress: true, accept_packed: false, run: false)
      begin
        stamped = principal.call(context)
        if stamped.nil?
          link.close("unauthorized")
        else
          host.accept(link, principal: stamped, kind: PeerKind::Client, options: options)
        end
      rescue
        link.close("authentication failed")
      end
      link.run
    end
  end
end
