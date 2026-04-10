//
//  PacketTunnelProvider.m
//  PacketTunnel
//
//  Created by LEI on 12/13/15.
//  Copyright © 2015 TouchingApp. All rights reserved.
//

#import "PacketTunnelProvider.h"
#import "ProxyManager.h"
#import "TunnelInterface.h"
#import "TunnelError.h"
#import "dns.h"
#import "CommUtils.h"
#import <sys/syslog.h>
#import <ShadowPath/ShadowPath.h>
#import <sys/socket.h>
#import <arpa/inet.h>
@import MMWormhole;
@import CocoaAsyncSocket;
#import "Profile.h"
#import "serverConnectivity.h"

#define REQUEST_CACHED @"requestsCached"    // Indicate that recent requests need update
#define LAST_TUNNEL_EVENT @"lastTunnelEvent"
#define LAST_TUNNEL_ERROR @"lastTunnelError"

#if DEBUG
#define WAIT_TIME      20000
#else
#define WAIT_TIME      2
#endif

@interface PacketTunnelProvider () <GCDAsyncSocketDelegate> {
    MMWormhole *_wormhole;
    GCDAsyncSocket *_statusSocket;
    GCDAsyncSocket *_statusClientSocket;
    BOOL _didSetupHockeyApp;
    NWPath *_lastPath;
    void (^_pendingStartCompletion)(NSError *);
    void (^_pendingStopCompletion)(void);
}
@end


@implementation PacketTunnelProvider {
    NSInteger _httpProxyPort;
    NSInteger _socksProxyPort;
}

- (void)recordTunnelEvent:(NSString *)event {
    NSLog(@"[PacketTunnel] %@", event);
    [[AppProfile sharedUserDefaults] setObject:event forKey:LAST_TUNNEL_EVENT];
    [[AppProfile sharedUserDefaults] synchronize];
}

- (void)recordTunnelError:(NSError *)error context:(NSString *)context {
    NSString *message;
    if (error) {
        message = [NSString stringWithFormat:@"%@: %@", context, error.localizedDescription ?: error.description];
    } else {
        message = context;
    }
    NSLog(@"[PacketTunnel][Error] %@", message);
    [[AppProfile sharedUserDefaults] setObject:message forKey:LAST_TUNNEL_ERROR];
    [[AppProfile sharedUserDefaults] synchronize];
}

- (void)clearTunnelDiagnostics {
    [[AppProfile sharedUserDefaults] removeObjectForKey:LAST_TUNNEL_EVENT];
    [[AppProfile sharedUserDefaults] removeObjectForKey:LAST_TUNNEL_ERROR];
    [[AppProfile sharedUserDefaults] synchronize];
}

- (void)startTunnelWithOptions:(NSDictionary *)options completionHandler:(void (^)(NSError *))completionHandler {
    [self openLog];
    NSLog(@"starting potatso tunnel...");
    [self clearTunnelDiagnostics];
    [self recordTunnelEvent:@"startTunnelWithOptions begin"];
    [self updateUserDefaults];
    NSError *error = [[TunnelInterface sharedInterface] setupWithPacketTunnelFlow:self.packetFlow];
    if (error) {
        [self recordTunnelError:error context:@"setupWithPacketTunnelFlow failed"];
        completionHandler(error);
        exit(1);
        return;
    }
    
    NSString *confContent = [NSString stringWithContentsOfURL:[AppProfile sharedProxyConfUrl] encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *json = [confContent jsonDictionary];
    Profile *profile = [[Profile alloc] initWithJSONDictionary:json];
    
    if (profile.server.length==0 || profile.serverPort==0) {
        NSError *profileError = [NSError errorWithDomain:@"iShadowsocksR" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"server address or port error"}];
        [self recordTunnelError:profileError context:@"profile validation failed"];
        completionHandler(profileError);
        return;
    }
    
    if (serverConnectivity(profile.server.UTF8String, (int)profile.serverPort, 10000) != 0){
        NSError *connectivityError = [NSError errorWithDomain:@"iShadowsocksR" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"serverConnectivity"}];
        [self recordTunnelError:connectivityError context:@"server connectivity check failed, continue starting tunnel"];
    } else {
        [self recordTunnelEvent:@"server connectivity check passed"];
    }

    [self recordTunnelEvent:[NSString stringWithFormat:@"profile validated server=%@ port=%ld", profile.server, (long)profile.serverPort]];
    _pendingStartCompletion = completionHandler;
    [self startAllProxyServers];
    [self startPacketForwarders];
    [self setupWormhole];
}

- (void)updateUserDefaults {
    [[AppProfile sharedUserDefaults] removeObjectForKey:REQUEST_CACHED];
    [[AppProfile sharedUserDefaults] synchronize];
    [[Settings shared] setStartTime:[NSDate date]];
}

- (void)setupWormhole {
    _wormhole = [[MMWormhole alloc] initWithApplicationGroupIdentifier: [AppProfile sharedGroupIdentifier] optionalDirectory:@"wormhole"];
    __weak typeof(self) weakSelf = self;
    [_wormhole listenForMessageWithIdentifier:@"getTunnelStatus" listener:^(id  _Nullable messageObject) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf->_wormhole passMessageObject:@"ok" identifier:@"tunnelStatus"];
    }];
    [_wormhole listenForMessageWithIdentifier:@"stopTunnel" listener:^(id  _Nullable messageObject) {
        [weakSelf stop];
    }];
    [_wormhole listenForMessageWithIdentifier:@"getTunnelConnectionRecords" listener:^(id  _Nullable messageObject) {
        NSMutableArray *records = [NSMutableArray array];
        struct log_client_states *p = log_clients;
        while (p) {
            struct client_state *client = p->csp;
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            char *url = client->http->url;
            if (url ==  NULL) {
                p = p->next;
                continue;
            }
            d[@"url"] = [NSString stringWithCString:url encoding:NSUTF8StringEncoding];
            d[@"method"] = @(client->http->gpc);
            for (int i=0; i < TIME_STAGE_COUNT; i++) {
                d[[NSString stringWithFormat:@"time%d", i]] = @(client->time_stages[i]);
            }
            d[@"version"] = @(client->http->ver);
            if (client->rule) {
                d[@"rule"] = [NSString stringWithCString:client->rule encoding:NSUTF8StringEncoding];
            }
            d[@"global"] = @(global_mode);
            d[@"routing"] = @(client->routing);
            d[@"forward_stage"] = @(client->current_forward_stage);
            if (client->http->remote_host_ip_addr_str) {
                d[@"ip"] = [NSString stringWithCString:client->http->remote_host_ip_addr_str encoding:NSUTF8StringEncoding];
            }
            d[@"responseCode"] = @(client->http->status);
            [records addObject:d];
            p = p->next;
        }
        NSString *result = [records jsonString];
        [self->_wormhole passMessageObject:result identifier:@"tunnelConnectionRecords"];
    }];
    [self setupStatusSocket];
}

- (void)setupStatusSocket {
    NSError *error;
    _statusSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)];
    [_statusSocket acceptOnInterface:@"127.0.0.1" port:0 error:&error];
    [_statusSocket performBlock:^{
        int port = sock_port(self->_statusSocket.socket4FD);
        [[AppProfile sharedUserDefaults] setObject:@(port) forKey:@"tunnelStatusPort"];
        [[AppProfile sharedUserDefaults] synchronize];
    }];
}

- (void)startAllProxyServers {
    [self recordTunnelEvent:@"startAllProxyServers"];
    [self startShadowsocks];
    [self startHttpProxyServer];
}

- (void)syncStartProxy: (NSString *)name completion: (void(^)(dispatch_group_t g, NSError **proxyError))handler {
    dispatch_group_t g = dispatch_group_create();
    __block NSError *proxyError;
    dispatch_group_enter(g);
    handler(g, &proxyError);
    long res = dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * WAIT_TIME));
    if (res != 0) {
        proxyError = [TunnelError errorWithMessage:@"timeout"];
    }
    if (proxyError) {
        [self recordTunnelError:proxyError context:[NSString stringWithFormat:@"start proxy %@ failed", name]];
        NSLog(@"start proxy: %@ error: %@", name, [proxyError localizedDescription]);
        exit(1);
        return;
    }
    [self recordTunnelEvent:[NSString stringWithFormat:@"start proxy %@ success", name]];
}

- (void)startShadowsocks {
    [self syncStartProxy: @"shadowsocks" completion:^(dispatch_group_t g, NSError *__autoreleasing *proxyError) {
        [[ProxyManager sharedManager] startShadowsocks:[AppProfile sharedProxyConfUrl] completion:^(int port, NSError *error) {
            self->_socksProxyPort = (NSInteger) port;
            *proxyError = error;
            dispatch_group_leave(g);
        }];
    }];
}

- (void)startHttpProxyServer {
    [self syncStartProxy: @"http" completion:^(dispatch_group_t g, NSError *__autoreleasing *proxyError) {
        [[ProxyManager sharedManager] startHttpProxyServer:[AppProfile sharedHttpProxyConfUrl] completion:^(int port, NSError *error) {
            self->_httpProxyPort = (NSInteger) port;
            *proxyError = error;
            dispatch_group_leave(g);
        }];
    }];
}

- (void)startPacketForwarders {
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTun2SocksFinished) name:kTun2SocksStoppedNotification object:nil];
    [self recordTunnelEvent:@"startPacketForwarders"];
    [self applyTunnelSettings:^(NSError *error) {
        __strong typeof(self) strongSelf = weakSelf;
        if (error == nil) {
            NSAssert(self->_socksProxyPort > 0, @"_socksProxyPort > 0");
            [strongSelf recordTunnelEvent:[NSString stringWithFormat:@"applyTunnelSettings success socksPort=%ld httpPort=%ld", (long)self->_socksProxyPort, (long)self->_httpProxyPort]];
            [weakSelf addObserver:weakSelf forKeyPath:@"defaultPath" options:NSKeyValueObservingOptionInitial context:nil];
            [[TunnelInterface sharedInterface] startTun2Socks:(int)self->_socksProxyPort];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[TunnelInterface sharedInterface] processPackets];
            });
        } else {
            [strongSelf recordTunnelError:error context:@"applyTunnelSettings failed"];
        }
        if (strongSelf->_pendingStartCompletion) {
            strongSelf->_pendingStartCompletion(error);
            strongSelf->_pendingStartCompletion = nil;
        }
    }];
}

- (void) applyTunnelSettings:(void (^)(NSError *error))completionHandler {
    NSString *generalConfContent = [NSString stringWithContentsOfURL:[AppProfile sharedGeneralConfUrl] encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *generalConf = [generalConfContent jsonDictionary];
    NSString *dns = generalConf[@"dns"];
    NEIPv4Settings *ipv4Settings = [[NEIPv4Settings alloc] initWithAddresses:@[@"192.0.2.1"] subnetMasks:@[@"255.255.255.0"]];
    NSArray *dnsServers;
    if (dns.length) {
        dnsServers = [dns componentsSeparatedByString:@","];
        NSLog(@"custom dns servers: %@", dnsServers);
    }else {
        dnsServers = [DNSConfig getSystemDnsServers];
        NSLog(@"system dns servers: %@", dnsServers);
    }
    ipv4Settings.includedRoutes = @[[NEIPv4Route defaultRoute]];
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"192.0.2.2"];
    settings.IPv4Settings = ipv4Settings;
    settings.MTU = @(TunnelMTU);
    NEProxySettings* proxySettings = [[NEProxySettings alloc] init];
    NSString *proxyServerName = @"localhost";
    NSAssert(_httpProxyPort > 0, @"_httpProxyPort > 0");

    proxySettings.HTTPEnabled = YES;
    proxySettings.HTTPServer = [[NEProxyServer alloc] initWithAddress:proxyServerName port:_httpProxyPort];
    proxySettings.HTTPSEnabled = YES;
    proxySettings.HTTPSServer = [[NEProxyServer alloc] initWithAddress:proxyServerName port:_httpProxyPort];
    proxySettings.excludeSimpleHostnames = YES;
    settings.proxySettings = proxySettings;
    NEDNSSettings *dnsSettings = [[NEDNSSettings alloc] initWithServers:dnsServers];
    dnsSettings.matchDomains = @[@""];
    settings.DNSSettings = dnsSettings;
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError * _Nullable error) {
        if (error) {
            [self recordTunnelError:error context:@"setTunnelNetworkSettings completion"];
        } else {
            [self recordTunnelEvent:@"setTunnelNetworkSettings success"];
        }
        if (completionHandler) {
            completionHandler(error);
        }
    }];
}

- (void)openLog {
    NSString *logFilePath = [AppProfile sharedLogUrl].path;
    [[NSFileManager defaultManager] createFileAtPath:logFilePath contents:nil attributes:nil];
    freopen([logFilePath cStringUsingEncoding:NSASCIIStringEncoding], "w+", stdout);
    freopen([logFilePath cStringUsingEncoding:NSASCIIStringEncoding], "w+", stderr);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"defaultPath"]) {
        if (self.defaultPath.status == NWPathStatusSatisfied && ![self.defaultPath isEqualToPath:_lastPath]) {
            if (!_lastPath) {
                _lastPath = self.defaultPath;
            }else {
                NSLog(@"received network change notifcation");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self applyTunnelSettings:nil];
                });
            }
        }else {
            _lastPath = self.defaultPath;
        }
    }
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler
{
	// Add code here to start the process of stopping the tunnel
    _pendingStopCompletion = completionHandler;
    [self stop];
}

- (void)stop {
    NSLog(@"stoping potatso tunnel...");
    [self recordTunnelEvent:@"stop tunnel requested"];
    [[AppProfile sharedUserDefaults] setObject:@(0) forKey:@"tunnelStatusPort"];
    [[AppProfile sharedUserDefaults] synchronize];
    [[ProxyManager sharedManager] stopHttpProxy];
    [[TunnelInterface sharedInterface] stop];
}

- (void)onTun2SocksFinished {
    [self recordTunnelEvent:@"onTun2SocksFinished"];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_pendingStopCompletion) {
        _pendingStopCompletion();
        _pendingStopCompletion = nil;
    }
    [self cancelTunnelWithError:nil];
    exit(EXIT_SUCCESS);
}

- (void)handleAppMessage:(NSData *)messageData completionHandler:(void (^)(NSData *))completionHandler {
    if (completionHandler != nil) {
        completionHandler(nil);
    }
}

- (void)sleepWithCompletionHandler:(void (^)(void))completionHandler {
    NSLog(@"sleeping potatso tunnel...");
	completionHandler();
}

- (void)wake {
    NSLog(@"waking potatso tunnel...");
}

#pragma mark - GCDAsyncSocket Delegate 

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
    _statusClientSocket = newSocket;
}

@end
