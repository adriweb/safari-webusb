#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
// Endpoint secrets stay in the signed app group's container. Bootstrap returns
// only an expiring, profile-bound credential and a derived connection key.
BOOL USBTransportHasSharedGroup(void);
NSDictionary * _Nullable USBPublishTransportEndpoint(uint16_t port, NSError **error);
void USBRemoveTransportEndpoint(NSDictionary *endpoint);
NSDictionary *USBTransportBootstrap(NSString *profile, NSString *origin);
NSDictionary * _Nullable USBVerifyTransportToken(NSString *token, NSString *origin, NSDictionary *endpoint);
NSString * _Nullable USBTransportProof(NSString *base64Key, NSString *message);
BOOL USBTransportConstantEqual(NSString *a, NSString *b);
NS_ASSUME_NONNULL_END
