/**
 * Copyright (C) 2011 Jonathan Diehl
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 * of the Software, and to permit persons to whom the Software is furnished to do
 * so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 * 
 * https://github.com/jdiehl/async-network
 */

#import "AsyncConnection.h"
#import "AsyncRequest.h"

#define AsyncConnectionHeaderSize sizeof(AsyncConnectionHeader)
const NSUInteger AsyncConnectionHeaderTag = 1;
const NSUInteger AsyncConnectionBodyTag = 2;
const NSUInteger AsyncConnectionTypeMessage = 1;
const NSUInteger AsyncConnectionTypeRequest = 2;
const NSUInteger AsyncConnectionTypeResponse = 3;

// private types and functions
NSData *HeaderToData(AsyncConnectionHeader header);
AsyncConnectionHeader DataToHeader(NSData *data);

@interface AsyncConnection ()
- (void)sendHeader:(AsyncConnectionHeader)header object:(id<NSCoding>)object;
- (void)sendResponse:(id<NSCoding>)object tag:(UInt32)tag;
- (void)respondToMessageWithHeader:(AsyncConnectionHeader)header object:(id<NSCoding>)object;
@end

@implementation AsyncConnection

Synthesize(socket)
Synthesize(delegate)
Synthesize(timeout)
Synthesize(netService)
Synthesize(host)
Synthesize(port)


// Create and return the run loop used for all network operations
+ (NSRunLoop *)networkRunLoop;
{
	return [NSRunLoop mainRunLoop];
}

// create a new connection with a netservice
+ (id)connectionWithNetService:(NSNetService *)netService;
{
	return [[self alloc] initWithNetService:netService];
}

// create a new connection with a socket
+ (id)connectionWithSocket:(AsyncSocket *)socket;
{
	return [[self alloc] initWithSocket:socket];
}

// create a new connection with host and port
+ (id)connectionWithHost:(NSString *)theHost port:(NSUInteger)thePort;
{
	return [[self alloc] initWithHost:theHost port:thePort];
}


#pragma mark init & clean up

// Init
- (id)init
{
    self = [super init];
    if (self) {
		self.timeout = AsyncNetworkDefaultConnectionTimeout;
        _responseBlocks = [NSMutableDictionary new];
        _currentBlockTag = 0;
    }
    return self;
}

// Init a connection with a netservice
- (id)initWithNetService:(NSNetService *)netService;
{
	self = [self init];
	if (self) {
		_netService = netService;
		_host = self.netService.hostName;
		_port = self.netService.port;
	}
	return self;
}

// Init a connection with a socket
- (id)initWithSocket:(AsyncSocket *)socket;
{
	self = [self init];
	if (self) {
		_socket = socket;
		self.socket.delegate = self;
		_port = self.socket.connectedPort;
		_host = self.socket.connectedHost;
	}
	return self;
}

// Init a connection with to a host and port
- (id)initWithHost:(NSString *)host port:(NSUInteger)port;
{
	self = [self init];
	if (self) {
		_host = host;
		_port = port;
	}
	return self;
}

// Clean up
- (void)dealloc
{
	// stop an active net service resolve
	if (self.netService.delegate == self) {
		self.netService.delegate = nil;
		[self.netService stop];
	}
	self.socket.delegate = nil;
}

// debug description
- (NSString *)description;
{
	return [NSString stringWithFormat:@"<%s host=%@ port=%d requests=%d>", object_getClassName(self), self.host, self.port, _responseBlocks.count];
}


#pragma mark - Control Methods

// Start the connection by creating a socket to connect to the host and port indicated in the request
- (void)start;
{
	if (self.socket) return;
	
	// resolve the net service if necessary
	// this will trigger start again once the net service was resolved
	if (self.netService && !self.host) {
		self.netService.delegate = self;
		[self.netService resolveWithTimeout:self.timeout];
		return;
	}
	
	// create the socket
	_socket = [AsyncSocket new];
	self.socket.delegate = self;
	
	// connect to host and port
	NSError *error;
	if (![self.socket connectToHost:self.host onPort:self.port withTimeout:self.timeout error:&error]) {
		CallOptionalDelegateMethod(connection:didFailWithError:, connection:self didFailWithError:error)
		_socket = nil;
		return;
	}
}

// Cancel an active connection
- (void)cancel;
{
	[self.socket disconnect];
	_socket = nil;
}

// are we connected?
- (BOOL)connected;
{
	return (self.socket.connectedHost != nil);
}

// send command and object with response block
- (void)sendCommand:(AsyncCommand)command object:(id<NSCoding>)object responseBlock:(AsyncNetworkResponseBlock)block;
{
	// prepare the header
	AsyncConnectionHeader header;
	header.type = block ? AsyncConnectionTypeRequest : AsyncConnectionTypeMessage;
	header.command = command;
	
	// store response block
	if (block) {
		header.blockTag = ++_currentBlockTag;
		[_responseBlocks setObject:block forKey:[NSNumber numberWithInteger:header.blockTag]];
	} else {
		header.blockTag = 0;
	}
	
	[self sendHeader:header object:object];
}

// send command and object without response block
- (void)sendCommand:(AsyncCommand)command object:(id<NSCoding>)object;
{
	[self sendCommand:command object:object responseBlock:nil];
}

// send object with command or response block
- (void)sendObject:(id<NSCoding>)object;
{
	[self sendCommand:0 object:object responseBlock:nil];
}


#pragma mark - Private Methods

// generic send
- (void)sendHeader:(AsyncConnectionHeader)header object:(id<NSCoding>)object;
{
	NSAssert(self.socket, @"AsyncConnection: attempted to send an object without being connected");
	
	// encode data
	NSData *bodyData = nil;
	if (object) {
		bodyData = [NSKeyedArchiver archivedDataWithRootObject:object];
		header.bodyLength = bodyData.length;
	} else {
		header.bodyLength = 0;
	}
	
	// send the header
	NSData *headerData = [NSData dataWithBytes:&header length:AsyncConnectionHeaderSize];
	[self.socket writeData:headerData withTimeout:self.timeout tag:AsyncConnectionHeaderTag];
	
	// send the body
	if (header.bodyLength > 0) [self.socket writeData:bodyData withTimeout:self.timeout tag:AsyncConnectionBodyTag];
}

// send a response
- (void)sendResponse:(id<NSCoding>)object tag:(UInt32)tag;
{
	// prepare the header
	AsyncConnectionHeader header;
	header.type = AsyncConnectionTypeResponse;
	header.command = 0;
	header.blockTag = tag;
	
	[self sendHeader:header object:object];
}

// get a response from the delegate for the given header and object
- (void)respondToMessageWithHeader:(AsyncConnectionHeader)header object:(id<NSCoding>)object;
{
	id<NSCoding> response = nil;
	AsyncNetworkResponseBlock block;
	switch (header.type) {
		case AsyncConnectionTypeMessage:
			// a message requires no response
			CallOptionalDelegateMethod(connection:didReceiveCommand:object:, connection:self didReceiveCommand:header.command object:object)
			break;
			
		case AsyncConnectionTypeRequest:
			// a request requires a response
			if ([self.delegate respondsToSelector:@selector(connection:respondToCommand:object:)]) {
				response = [self.delegate connection:self respondToCommand:header.command object:object];
			}
			[self sendResponse:response tag:header.blockTag];
			break;
			
		case AsyncConnectionTypeResponse:
			// a response to a request does not require a response
			block = [_responseBlocks objectForKey:[NSNumber numberWithInteger:header.blockTag]];
			if (block) block(object, nil);
			break;
	}
}


#pragma mark - NSNetServiceDelegate

// net service did resolve
- (void)netServiceDidResolveAddress:(NSNetService *)sender;
{
	_host = self.netService.hostName;
	_port = self.netService.port;
	self.netService.delegate = nil;
	[self start];
}


#pragma mark - AsycnSocketDelegate

/**
 Called when a socket connects and is ready for reading and writing.
 The host parameter will be an IP address, not a DNS name.
 **/
- (void)onSocket:(AsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port;
{
	// start reading length data
	[self.socket readDataToLength:AsyncConnectionHeaderSize withTimeout:self.timeout tag:AsyncConnectionHeaderTag];
	
	// inform delegate that we are connected
	CallOptionalDelegateMethod(connectionDidConnect:, connectionDidConnect:self)
}

/**
 In the event of an error, the socket is closed.
 You may call "unreadData" during this call-back to get the last bit of data off the socket.
 When connecting, this delegate method may be called
 before"onSocket:didAcceptNewSocket:" or "onSocket:didConnectToHost:".
 **/
- (void)onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)error;
{
	// inform delegate of the error
	if(error) {
		CallOptionalDelegateMethod(connection:didFailWithError:, connection:self didFailWithError:error)
    }
}

/**
 Called when a socket disconnects with or without error.  If you want to release a socket after it disconnects,
 do so here. It is not safe to do that during "onSocket:willDisconnectWithError:".
 
 If you call the disconnect method, and the socket wasn't already disconnected,
 this delegate method will be called before the disconnect method returns.
 **/
- (void)onSocketDidDisconnect:(AsyncSocket *)sock;
{
	CallOptionalDelegateMethod(connectionDidDisconnect:, connectionDidDisconnect:self)
}

/**
 Called when a new socket is spawned to handle a connection.  This method should return the run-loop of the
 thread on which the new socket and its delegate should operate. If omitted, [NSRunLoop currentRunLoop] is used.
 **/
- (NSRunLoop *)onSocket:(AsyncSocket *)sock wantsRunLoopForNewSocket:(AsyncSocket *)newSocket;
{
    return [[self class] networkRunLoop];
}

/**
 Called when a socket has completed reading the requested data into memory.
 Not called if there is an error.
 **/
- (void)onSocket:(AsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag;
{
    id object;
	switch(tag) {
			
		// header
		case AsyncConnectionHeaderTag:
			_lastHeader = DataToHeader(data);
			if (_lastHeader.bodyLength > 0) {
				// load the body data
				[self.socket readDataToLength:_lastHeader.bodyLength withTimeout:self.timeout tag:AsyncConnectionBodyTag];
			} else {
				// respond
				[self respondToMessageWithHeader:_lastHeader object:nil];
				[self.socket readDataToLength:AsyncConnectionHeaderSize withTimeout:self.timeout tag:AsyncConnectionHeaderTag];
			}
			break;

		// body
		case AsyncConnectionBodyTag:
            object = [NSKeyedUnarchiver unarchiveObjectWithData:data];
			[self respondToMessageWithHeader:_lastHeader object:object];
			[self.socket readDataToLength:AsyncConnectionHeaderSize withTimeout:self.timeout tag:AsyncConnectionHeaderTag];
			break;

		// unknown tag
		default:
			NSLog(@"AsyncConnection: ignoring unknown tag: %ld", tag);
	}
}


@end

// convert a header to data
NSData *HeaderToData(AsyncConnectionHeader header)
{
	UInt32 *encodedHeader = malloc(sizeof(AsyncConnectionHeader));
	encodedHeader[0] = CFSwapInt16LittleToHost(header.type);
	encodedHeader[1] = CFSwapInt32LittleToHost(header.command);
	encodedHeader[2] = CFSwapInt32LittleToHost(header.blockTag);
	encodedHeader[3] = CFSwapInt32LittleToHost(header.bodyLength);
	return [NSData dataWithBytesNoCopy:encodedHeader length:sizeof(header) freeWhenDone:YES];
}

// convert raw data to a header
AsyncConnectionHeader DataToHeader(NSData *data)
{
	assert(data.length == sizeof(AsyncConnectionHeader));
	
	const UInt32 *encodedHeader = (const UInt32 *)data.bytes;
	AsyncConnectionHeader header;
	header.type       = CFSwapInt16LittleToHost(encodedHeader[0]);
	header.command    = CFSwapInt32LittleToHost(encodedHeader[1]);
	header.blockTag   = CFSwapInt32LittleToHost(encodedHeader[2]);
	header.bodyLength = CFSwapInt32LittleToHost(encodedHeader[3]);
	return header;
}
