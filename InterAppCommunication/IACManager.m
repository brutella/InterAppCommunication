//
//  IACManager.m
//  IACSample
//
//  Created by Antonio Cabezuelo Vivo on 09/02/13.
//  Copyright (c) 2013 Antonio Cabezuelo Vivo. All rights reserved.
//

#import "IACManager.h"
#import "IACDelegate.h"
#import "IACClient.h"
#import "IACRequest.h"
#import "NSString+IACExtensions.h"


#if !__has_feature(objc_arc)
#error InterAppComutication must be built with ARC.
// You can turn on ARC for only InterAppComutication files by adding -fobjc-arc to the build phase for each of its files.
#endif


NSString * const IACErrorDomain       = @"com.iac.manager.error";
NSString * const IACClientErrorDomain = @"com.iac.client.error";

// x-callback-url strings
static NSString * const kXCUPrefix        = @"x-";
static NSString * const kXCUHost          = @"x-callback-url";
static NSString * const kXCUSource        = @"x-source";
static NSString * const kXCUSuccess       = @"x-success";
static NSString * const kXCUError         = @"x-error";
static NSString * const kXCUCancel        = @"x-cancel";
static NSString * const kXCUErrorCode     = @"error-Code";
static NSString * const kXCUErrorMessage  = @"errorMessage";

// IAC strings
static NSString * const kIACPrefix       = @"IAC";
static NSString * const kIACResponse     = @"IACRequestResponse";
static NSString * const kIACRequest      = @"IACRequestID";
static NSString * const kIACResponseType = @"IACResponseType";
static NSString * const kIACErrorDomain  = @"errorDomain";

typedef enum {
    IACResponseTypeSuccess,
    IACResponseTypeFailure,
    IACResponseTypeCancel
}IACResponseType;

@implementation IACManager {
    NSMutableDictionary *sessions;
    NSMutableDictionary *actions;
}

+ (IACManager*)sharedManager {
    static IACManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        sessions = [NSMutableDictionary dictionary];
        actions = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)handleOpenURL:(NSURL*)url {
    // An app can respond to multiple url schemes and the app can use different IACManagers for each one
    // so we test if the url is handled by this manager
    if (![url.scheme isEqualToString:self.callbackURLScheme]) {
        return NO;
    }
    
    // If the url is an x-callback-url compatible url we handle it
    if ([url.host isEqualToString:kXCUHost]) {
        NSString     *action     = [[url path] substringFromIndex:1];
        NSDictionary *parameters = [url.query parseURLParams];
        NSDictionary *actionParamters = [self removeProtocolParamsFromDictionary:parameters];
        
        
        // Lets see if this is a response to a previous call
        if ([action isEqualToString:kIACResponse]) {
            NSString *requestID = [parameters objectForKey:kIACRequest];
            
            IACRequest *request = [sessions objectForKey:requestID];
            if (request) {
                IACResponseType responseType = [[parameters objectForKey:kIACResponseType] intValue];
            
                switch (responseType) {
                    case IACResponseTypeSuccess:
                        if (request.successCalback) {
                            request.successCalback(actionParamters);
                        }
                        break;
                        
                    case IACResponseTypeFailure:
                        if (request.errorCalback) {
                            NSInteger errorCode = [request.client NSErrorCodeForXCUErrorCode:[parameters objectForKey:kXCUErrorCode]];
                            NSString *errorDomain = [parameters objectForKey:kIACErrorDomain] ? [parameters objectForKey:kIACErrorDomain] : IACClientErrorDomain;
                            NSError *error = [NSError errorWithDomain:errorDomain
                                                                 code:errorCode
                                                             userInfo:@{NSLocalizedDescriptionKey: [parameters objectForKey:kXCUErrorMessage]}];
                            
                            request.errorCalback(error);
                        }
                        break;
                        
                    case IACResponseTypeCancel:
                        if (request.successCalback) {
                            request.successCalback(nil);
                        }
                        break;
                        
                    default:
                        [sessions removeObjectForKey:requestID];
                        return NO;
                        break;
                }
            
                [sessions removeObjectForKey:requestID];
                return YES;
            }
            
            return NO;
        }
        
        // Lets see if there is somebody that handles this action
        if ([actions objectForKey:action] || [self.delegate supportsIACAction:action]) {
        
            IACSuccessBlock success = ^(NSDictionary *returnParams, BOOL cancelled) {
                if (cancelled) {
                    if ([parameters objectForKey:kXCUCancel]) {
                        [NSApp openURL:[NSURL URLWithString:[parameters objectForKey:kXCUCancel]]];
                    }
                } else if ([parameters objectForKey:kXCUSuccess]) {
                    [NSApp openURL:[NSURL URLWithString:[[parameters objectForKey:kXCUSuccess] stringByAppendingURLParams:returnParams]]];
                }
            };
            
            IACFailureBlock failure = ^(NSError *error) {
                if ([parameters objectForKey:kXCUError]) {
                    NSDictionary *errorParams = @{ kXCUErrorCode: @([error code]),
                                                   kXCUErrorMessage: [error localizedDescription],
                                                   kIACErrorDomain: [error domain]
                                                   };
                    [NSApp openURL:[NSURL URLWithString:[[parameters objectForKey:kXCUError] stringByAppendingURLParams:errorParams]]];
                }
            };

            // Handlers take precedence over the delegate
            if ([actions objectForKey:action]) {
                IACActionHandlerBlock actionHandler = [actions objectForKey:action];
                actionHandler(actionParamters, success, failure);
                return YES;
                
            } else if ([self.delegate supportsIACAction:action]) {
                [self.delegate performIACAction:action
                                     parameters:actionParamters
                                      onSuccess:success
                                      onFailure:failure];
                
                return YES;
            }
        } else {
            if ([parameters objectForKey:kXCUError]) {
                NSDictionary *errorParams = @{ kXCUErrorCode: @(IACErrorNotSupportedAction),
                                               kXCUErrorMessage: [NSString stringWithFormat:NSLocalizedString(@"'%@' is not an x-callback-url action supported by %@", nil), action, [self localizedAppName]],
                                               kIACErrorDomain: IACErrorDomain
                                             };
                [NSApp openURL:[NSURL URLWithString:[[parameters objectForKey:kXCUError] stringByAppendingURLParams:errorParams]]];
                return YES;
            }
        }
    }
    
    
    return NO;
}

- (void)sendIACRequest:(IACRequest*)request {
    
    if (![request.client isAppInstalled]) {
        if (request.errorCalback) {
            NSError *error = [NSError errorWithDomain:IACErrorDomain
                                                 code:IACErrorAppNotInstalled
                                             userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:NSLocalizedString(@"App with scheme '%@' is not installed in this device", nil), request.client.URLScheme]}];
            request.errorCalback(error);
        }
        return;
    }
    
    NSString *final_url = [NSString stringWithFormat:@"%@://%@/%@?", request.client.URLScheme, kXCUHost, request.action];
    final_url = [final_url stringByAppendingURLParams:request.parameters];
    final_url = [final_url stringByAppendingURLParams:@{kXCUSource: [self localizedAppName]}];
    
    if (self.callbackURLScheme) {
        NSString *xcu = [NSString stringWithFormat:@"%@://%@/%@?", self.callbackURLScheme, kXCUHost, kIACResponse];
        xcu = [xcu stringByAppendingURLParams:@{kIACRequest:request.requestID}];
        
        NSMutableDictionary *xcu_params = [NSMutableDictionary dictionary];
        
        if (request.successCalback) {
            [xcu_params setObject:[xcu stringByAppendingURLParams:@{kIACResponseType:@(IACResponseTypeSuccess)}] forKey:kXCUSuccess];
            [xcu_params setObject:[xcu stringByAppendingURLParams:@{kIACResponseType:@(IACResponseTypeCancel)}] forKey:kXCUCancel];
        }
        
        if (request.errorCalback) {
            [xcu_params setObject:[xcu stringByAppendingURLParams:@{kIACResponseType:@(IACResponseTypeFailure)}] forKey:kXCUError];
        }
        
        final_url = [final_url stringByAppendingURLParams:xcu_params];
    } else if (request.successCalback || request.errorCalback) {
        NSLog(@"WARNING: If you want to support callbacks from the remote app you must define a URL Scheme for this app to listen on");
    }
        
    [sessions setObject:request forKey:request.requestID];
    
    [NSApp openURL:[NSURL URLWithString:final_url]];
}


- (void)handleAction:(NSString*)action withBlock:(IACActionHandlerBlock)handler {
    [actions setObject:[handler copy] forKey:action];
}


- (NSDictionary*)removeProtocolParamsFromDictionary:(NSDictionary*)dictionary {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    // Removes all x-callback-url and all IAC parameters
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![key hasPrefix:kXCUPrefix] && ![key hasPrefix:kIACPrefix]) {
            [result setObject:obj forKey:key];
        }
    }];
    
    // Adds x-source parameter as this is needed to inform the user
    if ([dictionary objectForKey:kXCUSource]) {
        [result setObject:[dictionary objectForKey:kXCUSource] forKey:kXCUSource];
    }
    
    return result;
}

- (NSString*)localizedAppName {
    NSString *appname = [[[NSBundle mainBundle] localizedInfoDictionary] objectForKey:@"CFBundleDisplayName"];
    if (!appname) {
        appname = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
    }
    
    return appname;
}
                                                                  
@end
