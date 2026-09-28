#import "USBLoopbackServer.h"
#import "DeviceBridgeBackend.h"
#import "USBTransportAuth.h"
#import <Network/Network.h>

#ifndef USB_TRANSPORT_ADMISSION_SECONDS
#define USB_TRANSPORT_ADMISSION_SECONDS 10.0
#endif
static const NSUInteger USBMaximumFrame = 1536 * 1024;
static const NSUInteger USBMaximumConnections = 16;
static const NSUInteger USBMaximumPending = 128;
static const NSUInteger USBMaximumPeerPending = 32;
static const NSUInteger USBMaximumSessions = 128;
static const NSUInteger USBMaximumNonces = 1024;
static const void *USBTransportQueueKey = &USBTransportQueueKey;
static NSString * const USBOriginHeader = @"X-Safari-WebUSB-Origin";

static NSTimeInterval USBTransportNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL USBTransportString(id value, NSUInteger minimum, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] >= minimum && [value length] <= maximum;
}
static BOOL USBTransportPageOrigin(NSString *origin) {
    if (!USBTransportString(origin, 1, 2048)) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:origin];
    if (!url.host.length || url.user || url.password || url.query || url.fragment || url.path.length) return NO;
    return [url.scheme isEqual:@"https"] || ([url.scheme isEqual:@"http"] && ([@[@"localhost", @"127.0.0.1", @"::1", @"[::1]"] containsObject:url.host.lowercaseString]));
}
static BOOL USBTransportExtensionOrigin(NSString *origin) {
    if (!USBTransportString(origin, 1, 256)) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:origin];
    return [url.scheme isEqual:@"safari-web-extension"] && url.host.length && !url.user && !url.password && !url.port && !url.path.length && !url.query && !url.fragment;
}
static NSError *USBTransportError(NSString *description) {
    return [NSError errorWithDomain:@"org.webtilp.safariwebusb.transport" code:1 userInfo:@{NSLocalizedDescriptionKey: description}];
}

@class USBLoopbackPeer;
@interface USBLoopbackSession : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *origin;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL cleaned;
@property(nonatomic) NSTimeInterval lastSeen;
@end
@implementation USBLoopbackSession
@end

@interface USBLoopbackRequest : NSObject
@property(nonatomic) USBLoopbackPeer *peer;
@property(nonatomic) USBLoopbackSession *session;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSDictionary *message;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) BOOL cleanup;
@property(nonatomic) BOOL mandatory;
@end
@implementation USBLoopbackRequest
@end

@interface USBLoopbackServer ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) nw_listener_t listener;
@property(nonatomic) dispatch_source_t expiryTimer;
@property(nonatomic, copy) NSDictionary *endpoint;
@property(nonatomic, copy) NSString *backendInstance;
@property(nonatomic, copy) void (^startCompletion)(NSError *);
@property(nonatomic) NSMutableSet<USBLoopbackPeer *> *peers;
@property(nonatomic) NSMutableArray<USBLoopbackRequest *> *requests;
@property(nonatomic) NSMutableArray<USBLoopbackRequest *> *closeRequests;
@property(nonatomic) NSMutableArray<USBLoopbackPeer *> *cleanupPeers;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *usedNonces;
@property(nonatomic) USBLoopbackRequest *active;
@property(nonatomic) NSMutableSet<USBLoopbackRequest *> *aborts;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL stopping;
- (void)pump;
- (void)disconnectPeer:(USBLoopbackPeer *)peer;
- (void)received:(NSDictionary *)message peer:(USBLoopbackPeer *)peer;
@end

@interface USBLoopbackPeer : NSObject
@property(nonatomic, weak) USBLoopbackServer *server;
@property(nonatomic) nw_connection_t connection;
@property(nonatomic, copy) NSString *origin;
@property(nonatomic, copy) NSString *profile;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *challenge;
@property(nonatomic) BOOL authenticated;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL closing;
@property(nonatomic) NSUInteger outgoing;
@property(nonatomic) NSMutableSet<NSString *> *pending;
@property(nonatomic) NSMutableDictionary<NSString *, USBLoopbackSession *> *sessions;
@property(nonatomic) NSMutableArray<USBLoopbackSession *> *cleanupSessions;
- (void)receive;
- (void)send:(NSDictionary *)message completion:(void (^ _Nullable)(void))completion;
- (void)fail:(NSString *)name message:(NSString *)message;
@end

@implementation USBLoopbackPeer
- (instancetype)init {
    if ((self = [super init])) { _pending = [NSMutableSet set]; _sessions = [NSMutableDictionary dictionary]; }
    return self;
}
- (void)send:(NSDictionary *)message completion:(void (^)(void))completion {
    if (self.closed) return;
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (!data || data.length > USBMaximumFrame || self.outgoing >= USBMaximumPeerPending + 2) {
        [self.server disconnectPeer:self];
        return;
    }
    self.outgoing++;
    dispatch_data_t bytes = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_content_context_t context = nw_content_context_create("usb-response");
    nw_content_context_set_metadata_for_protocol(context, nw_ws_create_metadata(nw_ws_opcode_text));
    nw_connection_send(self.connection, bytes, context, true, ^(nw_error_t sendError) {
        self.outgoing--;
        if (sendError) [self.server disconnectPeer:self];
        else if (completion) completion();
    });
}
- (void)fail:(NSString *)name message:(NSString *)message {
    if (self.closed || self.closing) return;
    self.closing = YES;
    [self send:@{@"type": @"error", @"error": @{@"name": name, @"message": message}} completion:^{ [self.server disconnectPeer:self]; }];
    __weak USBLoopbackPeer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self.server.queue, ^{ USBLoopbackPeer *peer = weakSelf; if (peer) [peer.server disconnectPeer:peer]; });
}
- (void)receive {
    if (self.closed || self.closing) return;
    nw_connection_receive_message(self.connection, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        if (self.closed || self.closing) return;
        if (error || !content || !complete) { [self.server disconnectPeer:self]; return; }
        nw_protocol_metadata_t metadata = context ? nw_content_context_copy_protocol_metadata(context, nw_protocol_copy_ws_definition()) : NULL;
        if (!metadata || nw_ws_metadata_get_opcode(metadata) != nw_ws_opcode_text) { [self fail:@"TypeError" message:@"Only text JSON messages are accepted."]; return; }
        size_t limit = self.authenticated ? USBMaximumFrame : 8192;
        if (dispatch_data_get_size(content) > limit) { [self fail:@"QuotaExceededError" message:@"Transport message is too large."]; return; }
        const void *bytes = NULL; size_t length = 0;
        dispatch_data_t mapped = dispatch_data_create_map(content, &bytes, &length);
        NSData *data = [NSData dataWithBytes:bytes length:length];
        (void)mapped;
        id message = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![message isKindOfClass:NSDictionary.class]) { [self fail:@"TypeError" message:@"Transport message must be a JSON object."]; return; }
        [self.server received:message peer:self];
        [self receive];
    });
}
@end

@implementation USBLoopbackServer
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("org.webtilp.safariwebusb.loopback", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, USBTransportQueueKey, (__bridge void *)self, NULL);
        _peers = [NSMutableSet set]; _aborts = [NSMutableSet set]; _requests = [NSMutableArray array]; _closeRequests = [NSMutableArray array]; _cleanupPeers = [NSMutableArray array]; _usedNonces = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)completeStart:(NSError *)error {
    void (^completion)(NSError *) = self.startCompletion;
    self.startCompletion = nil;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}
- (void)startWithCompletion:(void (^)(NSError *))completion {
    dispatch_async(self.queue, ^{
        if (self.started) { dispatch_async(dispatch_get_main_queue(), ^{ completion(USBTransportError(@"USB transport is already started.")); }); return; }
        self.started = YES;
        self.startCompletion = completion;
        __weak USBLoopbackServer *eventServer = self;
        [DeviceBridgeBackend sharedBackend].eventHandler = ^(NSString *profile, NSString *identifier, NSDictionary *event) {
            USBLoopbackServer *server = eventServer;
            if (!server) return;
            dispatch_async(server.queue, ^{
                for (USBLoopbackPeer *peer in server.peers) {
                    USBLoopbackSession *session = peer.sessions[identifier];
                    if (peer.authenticated && !peer.closed && !peer.closing && session && !session.closed && [peer.profile isEqual:profile]) {
                        [peer send:@{@"type":@"event", @"session":identifier, @"event":event} completion:nil];
                        break;
                    }
                }
            });
        };
        nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcp) { nw_tcp_options_set_no_delay(tcp, true); });
        nw_parameters_set_local_endpoint(parameters, nw_endpoint_create_host("127.0.0.1", "0"));
        nw_protocol_options_t websocket = nw_ws_create_options(nw_ws_version_13);
        nw_ws_options_set_maximum_message_size(websocket, USBMaximumFrame);
        nw_ws_options_set_auto_reply_ping(websocket, true);
        nw_ws_options_set_client_request_handler(websocket, self.queue, ^nw_ws_response_t(nw_ws_request_t request) {
            __block NSString *origin = nil; __block NSUInteger count = 0;
            nw_ws_request_enumerate_additional_headers(request, ^bool(const char *name, const char *value) {
                if (strcasecmp(name, "Origin") == 0) { count++; origin = [NSString stringWithUTF8String:value]; }
                return true;
            });
            if (count != 1 || !USBTransportExtensionOrigin(origin)) return nw_ws_response_create(nw_ws_response_status_reject, NULL);
            nw_ws_response_t response = nw_ws_response_create(nw_ws_response_status_accept, NULL);
            // Network exposes the server response as per-connection metadata.
            // Retain the actual request Origin there, never in client JSON.
            nw_ws_response_add_additional_header(response, USBOriginHeader.UTF8String, origin.UTF8String);
            return response;
        });
        nw_protocol_stack_prepend_application_protocol(nw_parameters_copy_default_protocol_stack(parameters), websocket);
        self.listener = nw_listener_create(parameters);
        if (!self.listener) { [self completeStart:USBTransportError(@"Could not create USB transport listener.")]; return; }
        nw_listener_set_queue(self.listener, self.queue);
        __weak USBLoopbackServer *weakSelf = self;
        nw_listener_set_state_changed_handler(self.listener, ^(nw_listener_state_t state, nw_error_t error) {
            USBLoopbackServer *server = weakSelf;
            if (!server) return;
            if (state == nw_listener_state_ready && !server.endpoint && !server.stopping) {
                NSError *publishError;
                server.endpoint = USBPublishTransportEndpoint(nw_listener_get_port(server.listener), &publishError);
                if (!server.endpoint) { [server completeStart:publishError ?: USBTransportError(@"Could not publish USB transport endpoint.")]; [server stop]; return; }
                [server completeStart:nil];
            } else if (state == nw_listener_state_failed) {
                [server completeStart:USBTransportError([NSString stringWithFormat:@"USB transport listener failed (%d).", error ? nw_error_get_error_code(error) : 0])];
                [server stop];
            }
        });
        nw_listener_set_new_connection_handler(self.listener, ^(nw_connection_t connection) {
            USBLoopbackServer *server = weakSelf;
            if (!server || server.stopping || server.peers.count >= USBMaximumConnections) { nw_connection_cancel(connection); return; }
            USBLoopbackPeer *peer = [USBLoopbackPeer new]; peer.server = server; peer.connection = connection;
            [server.peers addObject:peer];
            nw_connection_set_queue(connection, server.queue);
            __weak USBLoopbackPeer *weakPeer = peer;
            nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t connectionError) {
                (void)connectionError;
                USBLoopbackPeer *peer = weakPeer;
                if (!peer) return;
                if (state == nw_connection_state_ready) {
                    nw_protocol_metadata_t metadata = nw_connection_copy_protocol_metadata(peer.connection, nw_protocol_copy_ws_definition());
                    nw_ws_response_t response = metadata ? nw_ws_metadata_copy_server_response(metadata) : NULL;
                    if (response) nw_ws_response_enumerate_additional_headers(response, ^bool(const char *name, const char *value) {
                        if (strcasecmp(name, USBOriginHeader.UTF8String) == 0) peer.origin = [NSString stringWithUTF8String:value];
                        return true;
                    });
                    if (!USBTransportExtensionOrigin(peer.origin)) { [peer fail:@"SecurityError" message:@"Missing trusted extension Origin."]; return; }
                    [peer receive];
                } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) [peer.server disconnectPeer:peer];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), server.queue, ^{
                USBLoopbackPeer *peer = weakPeer;
                if (peer && !peer.authenticated && !peer.closed) [peer fail:@"TimeoutError" message:@"USB transport authentication timed out."];
            });
            nw_connection_start(connection);
        });
        self.expiryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        dispatch_source_set_timer(self.expiryTimer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(self.expiryTimer, ^{ [weakSelf expire]; });
        dispatch_resume(self.expiryTimer);
        nw_listener_start(self.listener);
    });
}
- (void)stop {
    void (^stopOnQueue)(void) = ^{
        if (self.stopping) return;
        self.stopping = YES;
        if (self.endpoint) { USBRemoveTransportEndpoint(self.endpoint); self.endpoint = nil; }
        if (self.listener) nw_listener_cancel(self.listener);
        [self completeStart:USBTransportError(@"USB transport stopped before it became ready.")];
        for (USBLoopbackPeer *peer in self.peers.allObjects) [self disconnectPeer:peer];
        if (self.expiryTimer) { dispatch_source_cancel(self.expiryTimer); self.expiryTimer = nil; }
    };
    // Application termination cannot wait for a later queue turn to unpublish.
    if (dispatch_get_specific(USBTransportQueueKey) == (__bridge void *)self) stopOnQueue();
    else dispatch_sync(self.queue, stopOnQueue);
}
- (void)expire {
    NSTimeInterval wall = NSDate.date.timeIntervalSince1970, now = USBTransportNow();
    for (NSString *nonce in self.usedNonces.allKeys) if (self.usedNonces[nonce].doubleValue <= wall) [self.usedNonces removeObjectForKey:nonce];
    for (USBLoopbackPeer *peer in self.peers) {
        if (peer.closed) continue;
        for (NSString *identifier in peer.sessions.allKeys) {
            USBLoopbackSession *session = peer.sessions[identifier];
            if (session.closed && now - session.lastSeen > 90) [peer.sessions removeObjectForKey:identifier];
        }
    }
    [self pump];
}
- (void)requestError:(USBLoopbackRequest *)request name:(NSString *)name message:(NSString *)message {
    [request.peer.pending removeObject:request.identifier];
    [request.peer send:@{@"type": @"error", @"id": request.identifier, @"error": @{@"name": name, @"message": message}} completion:nil];
}
- (BOOL)abortingDevice:(NSString *)deviceId session:(USBLoopbackSession *)session peer:(USBLoopbackPeer *)peer {
    for (USBLoopbackRequest *abort in self.aborts)
        if (abort.peer == peer && abort.session == session && [abort.message[@"args"][@"deviceId"] isEqual:deviceId]) return YES;
    return NO;
}
- (void)abortSerialOutput:(USBLoopbackRequest *)request {
    NSString *deviceId = request.message[@"args"][@"deviceId"];
    for (USBLoopbackRequest *queued in self.requests.copy) {
        if (queued.peer == request.peer && queued.session == request.session && [queued.message[@"op"] isEqual:@"serial.write"] &&
            [queued.message[@"args"] isKindOfClass:NSDictionary.class] && [queued.message[@"args"][@"deviceId"] isEqual:deviceId]) {
            [self.requests removeObjectIdenticalTo:queued];
            [self requestError:queued name:@"AbortError" message:@"The serial write was canceled before it started."];
        }
    }
    [self.aborts addObject:request];
    // This narrowly scoped cancellation must reach the serial queue while its
    // write callback is pending. The router still validates the complete native
    // session, instance, origin and grant before touching the port.
    [[DeviceBridgeBackend sharedBackend] handleMessage:request.message profile:request.peer.profile completion:^(NSDictionary *response) {
        dispatch_async(self.queue, ^{
            [self.aborts removeObject:request];
            [request.peer.pending removeObject:request.identifier];
            if (!request.peer.closed && !request.peer.closing)
                [request.peer send:@{@"type": @"response", @"id": request.identifier, @"response": response} completion:nil];
            [self pump];
        });
    }];
}
- (void)received:(NSDictionary *)message peer:(USBLoopbackPeer *)peer {
    if (peer.closed || peer.closing) return;
    NSString *type = message[@"type"];
    if (!peer.authenticated) {
        if ([type isEqual:@"hello"] && !peer.challenge) {
            NSString *token = message[@"token"], *challenge = message[@"challenge"];
            if (!USBTransportString(token, 1, 8192) || !USBTransportString(challenge, 16, 128)) { [peer fail:@"SecurityError" message:@"Invalid USB transport greeting."]; return; }
            NSDictionary *claims = USBVerifyTransportToken(token, peer.origin, self.endpoint);
            NSString *nonce = claims[@"nonce"], *profile = claims[@"profile"], *key = claims[@"key"];
            if (!claims || !USBTransportString(nonce, 16, 128) || !USBTransportString(profile, 1, 200) || !USBTransportString(key, 1, 128) || self.usedNonces[nonce] || self.usedNonces.count >= USBMaximumNonces) { [peer fail:@"SecurityError" message:@"USB transport capability expired, invalid or already used."]; return; }
            self.usedNonces[nonce] = claims[@"expires"];
            peer.profile = [NSString stringWithFormat:@"%@:%@", profile, NSUUID.UUID.UUIDString];
            peer.key = key; peer.challenge = NSUUID.UUID.UUIDString;
            NSString *proof = USBTransportProof(key, [NSString stringWithFormat:@"server:%@:%@", challenge, peer.challenge]);
            if (!proof) { [peer fail:@"SecurityError" message:@"Could not authenticate USB transport."]; return; }
            [peer send:@{@"type": @"challenge", @"challenge": peer.challenge, @"proof": proof} completion:nil];
            return;
        }
        if ([type isEqual:@"authenticate"] && peer.challenge) {
            NSString *expected = USBTransportProof(peer.key, [@"client:" stringByAppendingString:peer.challenge]);
            if (!USBTransportString(message[@"proof"], 1, 128) || !expected || !USBTransportConstantEqual(message[@"proof"], expected)) { [peer fail:@"SecurityError" message:@"USB transport authentication failed."]; return; }
            peer.authenticated = YES; peer.key = nil; peer.challenge = nil;
            [peer send:@{@"type": @"ready"} completion:nil];
            return;
        }
        [peer fail:@"SecurityError" message:@"Authenticate before sending USB requests."]; return;
    }
    NSString *identifier = message[@"id"];
    if (![type isEqual:@"request"] || !USBTransportString(identifier, 1, 100) || ![message[@"message"] isKindOfClass:NSDictionary.class]) { [peer fail:@"TypeError" message:@"Invalid USB request envelope."]; return; }
    if ([peer.pending containsObject:identifier]) { [peer fail:@"TypeError" message:@"Duplicate pending USB request identifier."]; return; }
    USBLoopbackRequest *request = [USBLoopbackRequest new]; request.peer = peer; request.identifier = identifier; request.message = message[@"message"];
    NSString *sessionID = request.message[@"session"], *origin = request.message[@"origin"], *op = request.message[@"op"];
    if (!USBTransportString(sessionID, 16, 128) || !USBTransportPageOrigin(origin) || !USBTransportString(op, 1, 64)) { [self requestError:request name:@"SecurityError" message:@"USB requests require a document session and secure origin."]; return; }
    USBLoopbackSession *session = peer.sessions[sessionID];
    if (session && ![session.origin isEqual:origin]) { [self requestError:request name:@"SecurityError" message:@"USB document origin does not match its session."]; return; }
    if (session.closed) { [self requestError:request name:@"AbortError" message:@"USB document session has closed."]; return; }
    if ([op isEqual:@"closeSession"]) {
        if (!session) { [self requestError:request name:@"InvalidStateError" message:@"Unknown USB document session."]; return; }
        // Closing an admitted document is mandatory, even when ordinary work is
        // saturated or expired. One entry per existing session bounds this queue
        // by the connection/session caps; cleanup runs before ordinary requests.
        session.closed = YES; session.lastSeen = USBTransportNow();
        request.session = session; request.mandatory = YES;
        [peer.pending addObject:identifier]; [self.closeRequests addObject:request]; [self pump];
        return;
    }
    if (peer.pending.count >= USBMaximumPeerPending || self.requests.count + self.aborts.count + (self.active && !self.active.cleanup && !self.active.mandatory ? 1 : 0) >= USBMaximumPending) { [self requestError:request name:@"QuotaExceededError" message:@"Too many pending USB transport requests."]; return; }
    if ([op isEqual:@"serial.abortWrite"]) {
        id args = request.message[@"args"], version = request.message[@"version"];
        if (![args isKindOfClass:NSDictionary.class] || !USBTransportString(args[@"deviceId"], 1, 100) ||
            ![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() || ![version isEqual:@1]) {
            [self requestError:request name:@"TypeError" message:@"Invalid serial cancellation request."]; return;
        }
        if (!session || !self.backendInstance || ![self.backendInstance isEqual:request.message[@"instance"]]) {
            [self requestError:request name:@"InvalidStateError" message:@"The serial document session or native instance is no longer valid."]; return;
        }
        if ([self abortingDevice:args[@"deviceId"] session:session peer:peer]) {
            [self requestError:request name:@"InvalidStateError" message:@"Serial output cancellation is already in progress."]; return;
        }
        request.session = session; session.lastSeen = USBTransportNow();
        [peer.pending addObject:identifier];
        [self abortSerialOutput:request]; return;
    }
    if ([op isEqual:@"serial.write"] && [request.message[@"args"] isKindOfClass:NSDictionary.class] &&
        [self abortingDevice:request.message[@"args"][@"deviceId"] session:session peer:peer]) {
        [self requestError:request name:@"AbortError" message:@"Serial output cancellation is in progress."]; return;
    }
    if (!session) {
        if (peer.sessions.count >= USBMaximumSessions) { [self requestError:request name:@"QuotaExceededError" message:@"Too many USB document sessions."]; return; }
        session = [USBLoopbackSession new]; session.identifier = sessionID; session.origin = origin; peer.sessions[sessionID] = session;
    }
    session.lastSeen = USBTransportNow();
    request.session = session; request.deadline = session.lastSeen + USB_TRANSPORT_ADMISSION_SECONDS;
    [peer.pending addObject:identifier]; [self.requests addObject:request]; [self pump];
}
- (void)disconnectPeer:(USBLoopbackPeer *)peer {
    if (peer.closed) return;
    peer.closed = YES; peer.key = nil;
    nw_connection_cancel(peer.connection);
    for (NSMutableArray<USBLoopbackRequest *> *queue in @[self.requests, self.closeRequests])
        for (USBLoopbackRequest *request in queue.copy) if (request.peer == peer) { [peer.pending removeObject:request.identifier]; [queue removeObjectIdenticalTo:request]; }
    // Keep the peer in the bounded connection set until its cleanup finishes.
    // Any already-running grant finishes first; its session is then closed.
    peer.cleanupSessions = [peer.sessions.allValues mutableCopy];
    [self.cleanupPeers addObject:peer];
    [self pump];
}
- (void)pump {
    NSTimeInterval now = USBTransportNow();
    for (USBLoopbackRequest *request in self.requests.copy) {
        if (request.deadline <= now) { [self.requests removeObjectIdenticalTo:request]; [self requestError:request name:@"TimeoutError" message:@"USB transport queue was busy. The operation was not started."]; }
    }
    // Keep request admission, fd cleanup and any new writes behind every
    // outstanding cancellation callback, including after a peer disconnects.
    if (self.active || self.aborts.count) return;
    USBLoopbackRequest *request = nil;
    while (self.cleanupPeers.count) {
        USBLoopbackPeer *peer = self.cleanupPeers.firstObject;
        if (!self.backendInstance || !peer.cleanupSessions.count) { [self.cleanupPeers removeObjectAtIndex:0]; [self.peers removeObject:peer]; continue; }
        USBLoopbackSession *session = peer.cleanupSessions.firstObject;
        [peer.cleanupSessions removeObjectAtIndex:0];
        if (session.cleaned) continue;
        request = [USBLoopbackRequest new]; request.peer = peer; request.session = session; request.cleanup = YES;
        request.message = @{@"version": @1, @"op": @"closeSession", @"session": session.identifier, @"origin": session.origin, @"instance": self.backendInstance, @"args": @{}};
        break;
    }
    if (!request && self.closeRequests.count) {
        request = self.closeRequests.firstObject; [self.closeRequests removeObjectAtIndex:0];
    }
    while (!request && self.requests.count) {
        request = self.requests.firstObject; [self.requests removeObjectAtIndex:0];
        if (request.peer.closed || request.peer.closing || (request.session.closed && ![request.message[@"op"] isEqual:@"closeSession"])) { [self requestError:request name:@"AbortError" message:@"The USB document closed before the operation started."]; request = nil; }
    }
    if (!request) return;
    self.active = request;
    [[DeviceBridgeBackend sharedBackend] handleMessage:request.message profile:request.peer.profile completion:^(NSDictionary *response) {
        dispatch_async(self.queue, ^{
            if (USBTransportString(response[@"instance"], 1, 128)) self.backendInstance = response[@"instance"];
            self.active = nil;
            if ([request.message[@"op"] isEqual:@"closeSession"] && [response[@"ok"] boolValue]) request.session.cleaned = YES;
            if (!request.cleanup) {
                [request.peer.pending removeObject:request.identifier];
                if (!request.peer.closed && !request.peer.closing) [request.peer send:@{@"type": @"response", @"id": request.identifier, @"response": response} completion:nil];
            }
            [self pump];
        });
    }];
}
@end
