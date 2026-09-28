// Optional read-only diagnostic. Never grants, claims, or sends application transfers.
#import "USBBackend.h"
int main(void) {
    @autoreleasepool {
        NSDictionary *response = [[USBBackend sharedBackend] handleMessage:@{@"version": @1, @"op": @"enumerate"} profile:@"diagnostic"];
        NSData *json = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return [response[@"ok"] boolValue] ? 0 : 1;
    }
}
