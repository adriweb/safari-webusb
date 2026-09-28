#import "../DevicePermissionStore.h"
static NSUInteger assertions;
#define CHECK(...) do { assertions++; if (!(__VA_ARGS__)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#__VA_ARGS__); exit(1); } } while(0)
static NSDictionary *remember(DevicePermissionStore *store, NSString *profile, NSString *origin, NSString *kind, NSString *identity, BOOL durable) {
    NSError *error=nil;
    NSDictionary *record=[store rememberProfile:profile origin:origin kind:kind identity:identity name:@"Calculator" durable:durable error:&error];
    CHECK(record && !error); return record;
}
static void writeJSON(NSURL *url,id value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];CHECK([data writeToURL:url atomically:YES]);
}
int main(void) { @autoreleasepool {
    NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"device-permissions-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSURL *file=[directory URLByAppendingPathComponent:@"permissions.json"];
    DevicePermissionStore *store=[[DevicePermissionStore alloc] initWithURL:file];
    CHECK([store recordsForProfile:@"profile-1"].count==0);
    NSDictionary *usb=remember(store,@"profile-1",@"https://example.org",@"usb",@"serial-identity",YES);
    NSDictionary *attachment=remember(store,@"profile-1",@"https://example.org",@"hid",@"boot:attachment-identity",NO);
    NSDictionary *otherOrigin=remember(store,@"profile-1",@"https://other.example",@"usb",@"serial-identity",YES);
    NSDictionary *otherProfile=remember(store,@"profile-2",@"https://example.org",@"usb",@"serial-identity",YES);
    CHECK([store recordsForProfile:@"profile-1"].count==3);
    CHECK([store recordsForProfile:@"profile-2"].count==1);
    CHECK([store recordForProfile:@"profile-1" origin:@"https://example.org" kind:@"usb" identity:@"different"]==nil);
    CHECK([remember(store,@"profile-1",@"https://example.org",@"usb",@"serial-identity",YES)[@"id"] isEqual:usb[@"id"]]);
    CHECK([store recordsForProfile:@"profile-1"].count==3);
    // A new process gets the same authorization keys and manager IDs.
    store=[[DevicePermissionStore alloc] initWithURL:file];
    CHECK([[store recordForProfile:@"profile-1" origin:@"https://example.org" kind:@"usb" identity:@"serial-identity"] isEqual:usb]);
    CHECK([[store recordForProfile:@"profile-1" origin:@"https://example.org" kind:@"hid" identity:@"boot:attachment-identity"] isEqual:attachment]);
    CHECK(![attachment[@"durable"] boolValue]);
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    CHECK(([attributes[NSFilePosixPermissions] unsignedIntegerValue]&0777)==0600);
    NSError *error=nil;
    CHECK([store removeIDs:@[usb[@"id"]] profile:@"profile-2" error:&error] && !error);
    CHECK([store recordsForProfile:@"profile-1"].count==3);
    CHECK([store removeIDs:@[usb[@"id"]] profile:@"profile-1" error:&error] && !error);
    store=[[DevicePermissionStore alloc] initWithURL:file];
    CHECK([store recordForProfile:@"profile-1" origin:@"https://example.org" kind:@"usb" identity:@"serial-identity"]==nil);
    CHECK([[store recordForProfile:@"profile-1" origin:@"https://other.example" kind:@"usb" identity:@"serial-identity"] isEqual:otherOrigin]);
    CHECK([[store recordForProfile:@"profile-2" origin:@"https://example.org" kind:@"usb" identity:@"serial-identity"] isEqual:otherProfile]);
    // Malformed/duplicated records fail closed instead of accepting a valid prefix.
    NSArray *invalid=@[@{},@{@"version":@YES,@"permissions":@[usb]},@{@"version":@2,@"permissions":@[usb]},@{@"version":@1,@"permissions":@[usb,@{}]},
        @{@"version":@1,@"permissions":@[usb,usb]},@{@"version":@1,@"permissions":@{}},@[]];
    for (id value in invalid) {
        writeJSON(file,value);store=[[DevicePermissionStore alloc] initWithURL:file];CHECK([store recordsForProfile:@"profile-1"].count==0);
    }
    NSMutableDictionary *duplicateScope=[usb mutableCopy];duplicateScope[@"id"]=NSUUID.UUID.UUIDString;
    writeJSON(file,@{@"version":@1,@"permissions":@[usb,duplicateScope]});
    CHECK([[[DevicePermissionStore alloc] initWithURL:file] recordsForProfile:@"profile-1"].count==0);
    NSMutableDictionary *invalidBoolean=[usb mutableCopy];invalidBoolean[@"durable"]=@1;
    writeJSON(file,@{@"version":@1,@"permissions":@[invalidBoolean]});
    CHECK([[[DevicePermissionStore alloc] initWithURL:file] recordsForProfile:@"profile-1"].count==0);
    CHECK([[NSMutableData dataWithLength:4*1024*1024+1] writeToURL:file atomically:YES]);
    CHECK([[[DevicePermissionStore alloc] initWithURL:file] recordsForProfile:@"profile-1"].count==0);
    // Failed atomic replacement must not create an in-memory-only remembered grant.
    NSURL *blocked=[file URLByAppendingPathComponent:@"not-a-directory"];
    store=[[DevicePermissionStore alloc] initWithURL:blocked];error=nil;
    CHECK([store rememberProfile:@"profile-1" origin:@"https://example.org" kind:@"usb" identity:@"device" name:@"Calculator" durable:YES error:&error]==nil);
    CHECK(error && [store recordsForProfile:@"profile-1"].count==0);
    // Quotas bound a long-lived profile and invalid identities are rejected.
    store=[[DevicePermissionStore alloc] initWithURL:nil];
    for(NSUInteger n=0;n<512;n++) remember(store,@"bounded",@"https://example.org",@"serial",[@(n) stringValue],YES);
    error=nil;
    CHECK([store rememberProfile:@"bounded" origin:@"https://example.org" kind:@"serial" identity:@"overflow" name:@"Port" durable:YES error:&error]==nil && error);
    CHECK([store recordsForProfile:@"bounded"].count==512);
    error=nil;
    CHECK([store rememberProfile:@"other" origin:@"https://example.org" kind:@"unknown" identity:@"identity" name:@"Port" durable:YES error:&error]==nil && error);
    CHECK([NSFileManager.defaultManager removeItemAtURL:directory error:nil]);
    printf("DevicePermissionStore: %lu assertions passed\n",(unsigned long)assertions);
}return 0;}
