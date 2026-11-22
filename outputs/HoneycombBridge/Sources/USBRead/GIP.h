#import <Foundation/Foundation.h>
typedef struct { uint32_t total[16], nextOffset[16]; BOOL requested[16], powered[16], powerAfterIdentify, completeAfterPower, authenticate; CFMutableDictionaryRef clients; uint8_t sequence; CFArrayRef afterAuth; } GIPResearchState;
NSArray<NSData *> *GIPResearchResponses(GIPResearchState *state, NSData *packet, NSMutableArray<NSDictionary *> *events);
BOOL GIPResearchSelfTest(void);

void GIPResearchDispose(GIPResearchState *state);
