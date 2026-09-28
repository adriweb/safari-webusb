// Include the actual implementation to exercise credential issuance without
// accessing a real App Group or writing transport discovery files.
#import "../USBTransportAuth.m"
static NSUInteger assertions;
#define CHECK(expression) do { assertions++; if (!(expression)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); exit(1); } } while (0)
static NSString *signedClaims(NSDictionary *claims, NSDictionary *endpoint) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:claims options:NSJSONWritingSortedKeys error:NULL];
    NSString *payload = [json base64EncodedStringWithOptions:0];
    return [NSString stringWithFormat:@"%@.%@", payload, USBTransportProof(endpoint[@"secret"], [@"token:" stringByAppendingString:payload])];
}
int main(void) {
    @autoreleasepool {
        NSString *origin = @"safari-web-extension://f482087c-1bd8-4f18-88b1-a31d7c6be43b";
        NSString *profile = @"profile-from-safari";
        NSData *secret = [NSMutableData dataWithLength:32];
        NSDictionary *endpoint = @{@"version":@1, @"instance":NSUUID.UUID.UUIDString, @"port":@54321, @"secret":[secret base64EncodedStringWithOptions:0]};
        NSDictionary *bootstrap = USBMakeTransportBootstrap(profile, origin, endpoint);
        CHECK([bootstrap[@"ok"] isEqual:@YES]);
        CHECK([bootstrap[@"url"] isEqual:@"ws://127.0.0.1:54321/"]);
        CHECK(bootstrap[@"secret"] == nil && bootstrap[@"instance"] == nil);
        CHECK(![bootstrap[@"key"] isEqual:endpoint[@"secret"]]);
        NSDictionary *claims = USBVerifyTransportToken(bootstrap[@"token"], origin, endpoint);
        CHECK([claims[@"profile"] isEqual:profile]);
        CHECK(USBTransportUUID(claims[@"nonce"]));
        CHECK([claims[@"expires"] doubleValue] > NSDate.date.timeIntervalSince1970 + 28);
        CHECK([claims[@"key"] isEqual:bootstrap[@"key"]]);
        NSDictionary *second = USBMakeTransportBootstrap(profile, origin, endpoint);
        CHECK(![second[@"token"] isEqual:bootstrap[@"token"]]);
        CHECK(![second[@"key"] isEqual:bootstrap[@"key"]]);
        CHECK(USBVerifyTransportToken(bootstrap[@"token"], @"safari-web-extension://00000000-0000-0000-0000-000000000000", endpoint) == nil);
        NSMutableDictionary *other = [endpoint mutableCopy];
        other[@"instance"] = NSUUID.UUID.UUIDString;
        CHECK(USBVerifyTransportToken(bootstrap[@"token"], origin, other) == nil);
        NSMutableData *otherKey = [NSMutableData dataWithLength:32];
        ((uint8_t *)otherKey.mutableBytes)[0] = 1;
        other[@"instance"] = endpoint[@"instance"];
        other[@"secret"] = [otherKey base64EncodedStringWithOptions:0];
        CHECK(USBVerifyTransportToken(bootstrap[@"token"], origin, other) == nil);
        CHECK(USBVerifyTransportToken([bootstrap[@"token"] stringByAppendingString:@"x"], origin, endpoint) == nil);
        CHECK(USBVerifyTransportToken(@"malformed", origin, endpoint) == nil);
        CHECK(USBVerifyTransportToken(@"a.b.c", origin, endpoint) == nil);
        NSArray *parts = [bootstrap[@"token"] componentsSeparatedByString:@"."];
        NSMutableDictionary *body = [[NSJSONSerialization JSONObjectWithData:[[NSData alloc] initWithBase64EncodedString:parts[0] options:0] options:0 error:NULL] mutableCopy];
        body[@"profile"] = @"attacker-profile";
        NSString *modifiedPayload = [[NSJSONSerialization dataWithJSONObject:body options:0 error:NULL] base64EncodedStringWithOptions:0];
        CHECK(USBVerifyTransportToken([NSString stringWithFormat:@"%@.%@", modifiedPayload, parts[1]], origin, endpoint) == nil);
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        body[@"issued"] = @(now - 60); body[@"expires"] = @(now - 30);
        CHECK(USBVerifyTransportToken(signedClaims(body, endpoint), origin, endpoint) == nil);
        body[@"issued"] = @(now + 60); body[@"expires"] = @(now + 90);
        CHECK(USBVerifyTransportToken(signedClaims(body, endpoint), origin, endpoint) == nil);
        body[@"issued"] = @(now); body[@"expires"] = @(now + 300);
        CHECK(USBVerifyTransportToken(signedClaims(body, endpoint), origin, endpoint) == nil);
        body[@"expires"] = @(now + 30); body[@"nonce"] = @"not-a-nonce";
        CHECK(USBVerifyTransportToken(signedClaims(body, endpoint), origin, endpoint) == nil);
        body[@"nonce"] = NSUUID.UUID.UUIDString; body[@"version"] = @YES;
        CHECK(USBVerifyTransportToken(signedClaims(body, endpoint), origin, endpoint) == nil);
        for (NSString *bad in @[@"null", @"https://example.com", @"safari-web-extension://not-a-uuid", [origin stringByAppendingString:@"/"], [origin stringByAppendingString:@":1234"], [origin uppercaseString]]) {
            CHECK(![USBMakeTransportBootstrap(profile, bad, endpoint)[@"ok"] boolValue]);
            CHECK(USBVerifyTransportToken(bootstrap[@"token"], bad, endpoint) == nil);
        }
        NSString *serverProof = USBTransportProof(bootstrap[@"key"], @"server:client-challenge:server-challenge");
        CHECK(USBTransportConstantEqual(serverProof, USBTransportProof(claims[@"key"], @"server:client-challenge:server-challenge")));
        CHECK(!USBTransportConstantEqual(serverProof, USBTransportProof(claims[@"key"], @"server:other-client:server-challenge")));
        CHECK(!USBTransportConstantEqual(serverProof, USBTransportProof(claims[@"key"], @"client:server-challenge")));
        CHECK(!USBTransportConstantEqual(@"a", @"b"));
        CHECK(!USBTransportConstantEqual(@"a", @"aa"));
        CHECK(USBTransportProof(@"bad-key", @"message") == nil);
        printf("USBTransportAuth: %lu assertions passed\n", (unsigned long)assertions);
    }
}
