#import <Foundation/Foundation.h>
@interface GIPAuth : NSObject
@property(nonatomic, readonly) BOOL complete;
@property(nonatomic, readonly) NSString *failure;
@property(nonatomic, readonly) NSString *phase;
- (NSData *)begin;
- (NSArray<NSData *> *)receive:(NSData *)payload;
@end
BOOL GIPAuthSelfTest(void);
