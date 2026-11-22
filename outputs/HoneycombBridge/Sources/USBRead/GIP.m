#import "GIP.h"
#import "GIPAuth.h"
static BOOL integer(const uint8_t *bytes, NSUInteger size, NSUInteger *position, uint32_t *result) {
    *result = 0;
    for (unsigned i = 0; i < 4 && *position < size; i++) {
        uint8_t byte = bytes[(*position)++];
        *result |= (uint32_t)(byte & 127) << (7 * i);
        if (!(byte & 128)) return YES;
    }
    return NO;
}
@interface GIPClient : NSObject
@property(nonatomic, strong) NSMutableData *incoming;
@property(nonatomic) uint8_t incomingCommand;
@property(nonatomic) uint8_t incomingSequence;
@property(nonatomic, strong) NSData *pending;
@property(nonatomic) NSUInteger sent;
@property(nonatomic) uint8_t pendingSequence;
@property(nonatomic, strong) GIPAuth *auth;
@property(nonatomic) BOOL capabilitiesRequested;
@end
@implementation GIPClient
@end
static GIPClient *clientState(GIPResearchState *state, unsigned client) {
    if (!state->clients) state->clients = (CFMutableDictionaryRef)CFBridgingRetain([NSMutableDictionary dictionary]);
    NSMutableDictionary *clients = (__bridge NSMutableDictionary *)state->clients;
    if (!clients[@(client)]) clients[@(client)] = [GIPClient new];
    return clients[@(client)];
}
void GIPResearchDispose(GIPResearchState *state) {
    if (state->clients) { CFRelease(state->clients); state->clients = NULL; }
}
static NSData *varint(uint32_t value) {
    NSMutableData *bytes = [NSMutableData data];
    do { uint8_t byte = value & 127; value >>= 7; if (value) byte |= 128; [bytes appendBytes:&byte length:1]; } while (value);
    return bytes;
}
static NSData *frame(uint8_t command, uint8_t options, uint8_t sequence, NSData *payload, uint32_t offset) {
    uint8_t prefix[] = {command, options, sequence};
    NSMutableData *header = [NSMutableData dataWithBytes:prefix length:3];
    NSMutableData *size = [varint((uint32_t)payload.length) mutableCopy];
    NSData *off = (options & 128) ? varint(offset) : [NSData data];
    if ((3 + size.length + off.length) % 2) {
        ((uint8_t *)size.mutableBytes)[size.length - 1] |= 128;
        uint8_t zero = 0; [size appendBytes:&zero length:1];
    }
    [header appendData:size]; [header appendData:off]; [header appendData:payload]; return header;
}
static void appendAuth(GIPResearchState *state, unsigned client, GIPClient *session, NSData *message, NSMutableArray *responses) {
    if (++state->sequence == 0) ++state->sequence;
    if (message.length <= 58) {
        [responses addObject:frame(6, (message.length == 2 ? 0x20 : 0x30) | client, state->sequence, message, 0)];
    } else {
        session.pending = message; session.sent = 58; session.pendingSequence = state->sequence;
        [responses addObject:frame(6, 0xf0 | client, state->sequence, [message subdataWithRange:NSMakeRange(0, 58)], (uint32_t)message.length)];
    }
}
NSArray<NSData *> *GIPResearchResponses(GIPResearchState *state, NSData *packet, NSMutableArray<NSDictionary *> *events) {
    NSMutableArray<NSData *> *responses = [NSMutableArray array];
    const uint8_t *bytes = packet.bytes; NSUInteger position = 0;
    while (position < packet.length) {
        if (packet.length - position < 4) goto malformed;
        uint8_t command = bytes[position++], options = bytes[position++], sequence = bytes[position++];
        uint32_t size = 0, offset = 0;
        if (!integer(bytes, packet.length, &position, &size)) goto malformed;
        if ((options & 128) && !integer(bytes, packet.length, &position, &offset)) goto malformed;
        if (size > packet.length - position) goto malformed;
        unsigned client = options & 15;
        GIPClient *session = clientState(state, client);
        if ((options & 64) && !(options & 128)) goto malformed;
        if (options & 64) {
            if (!offset || offset > 65535) goto malformed;
            state->total[client] = offset; state->nextOffset[client] = 0; offset = 0;
            session.incoming = [NSMutableData dataWithLength:state->total[client]];
            session.incomingCommand = command; session.incomingSequence = sequence;
        }
        if ((options & 128) && (offset > state->total[client] || size > state->total[client] - offset)) goto malformed;
        if (options & 128) {
            if (!session.incoming || command != session.incomingCommand || sequence != session.incomingSequence || offset != state->nextOffset[client]) goto malformed;
            if (size) [session.incoming replaceBytesInRange:NSMakeRange(offset, size) withBytes:bytes + position];
            state->nextOffset[client] += size;
            if (!size && offset != state->total[client]) goto malformed;
        }
        [events addObject:@{@"event": @"gip_header", @"command": @(command), @"options": @(options), @"sequence": @(sequence), @"client": @(client), @"payload_length": @(size), @"chunk_offset": @(offset), @"chunk_total": @(state->total[client])}];
        if (options & 16) {
            uint32_t end = offset + size, remaining = (options & 128) ? state->total[client] - end : 0;
            if (end > 65535 || remaining > 65535) goto malformed;
            uint8_t ack[] = {1, 0x20 | client, sequence, 9, 0, command, 0x20 | client,
                end & 255, (end >> 8) & 255, 0, 0, remaining & 255, (remaining >> 8) & 255};
            [responses addObject:[NSData dataWithBytes:ack length:sizeof(ack)]];
        }
        if (command == 2 && (options & 32) && !(options & 128) && size == 28 && !state->requested[client]) {
            if (++state->sequence == 0) ++state->sequence;
            uint8_t identify[] = {4, 0x20 | client, state->sequence, 0};
            [responses addObject:[NSData dataWithBytes:identify length:sizeof(identify)]];
            state->requested[client] = YES;
        }
        NSData *message = nil;
        if (!(options & 128)) message = [NSData dataWithBytes:bytes + position length:size];
        else if (!size) { message = [session.incoming copy]; session.incoming = nil; }
        if (command == 1 && (options & 32) && size == 9 && session.pending && bytes[position + 1] == 6 && sequence == session.pendingSequence) {
            NSUInteger acknowledged = bytes[position + 3] | ((NSUInteger)bytes[position + 4] << 8);
            if (acknowledged != session.sent) goto malformed;
            if (acknowledged < session.pending.length) {
                while (session.sent < session.pending.length) {
                    NSUInteger n = MIN(58, session.pending.length - session.sent);
                    uint8_t outgoing = 0xa0 | client;
                    if (session.sent + n == session.pending.length) outgoing |= 16;
                    [responses addObject:frame(6, outgoing, session.pendingSequence, [session.pending subdataWithRange:NSMakeRange(session.sent, n)], (uint32_t)session.sent)];
                    session.sent += n;
                }
            } else {
                [responses addObject:frame(6, 0xa0 | client, session.pendingSequence, [NSData data], (uint32_t)session.pending.length)];
                session.pending = nil;
            }
        }
        if (message) [events addObject:@{@"event": @"gip_message", @"client": @(client), @"command": @(command), @"length": @(message.length)}];
        BOOL identified = command == 4 && (options & 32) && message.length >= 32;
        if (identified && state->powerAfterIdentify && !state->powered[client]) {
            if (++state->sequence == 0) ++state->sequence;
            uint8_t power[] = {5, 0x20 | client, state->sequence, 1, 0};
            [responses addObject:[NSData dataWithBytes:power length:sizeof(power)]];
            if (state->completeAfterPower) {
                if (++state->sequence == 0) ++state->sequence;
                uint8_t complete[] = {6, 0x20 | client, state->sequence, 2, 1, 0};
                [responses addObject:[NSData dataWithBytes:complete length:sizeof(complete)]];
                [events addObject:@{@"event": @"gip_session_complete_requested", @"client": @(client), @"experimental": @YES}];
            }
            if (state->authenticate) {
                session.auth = [GIPAuth new]; NSData *hello = [session.auth begin];
                if (!hello) goto authFailed;
                appendAuth(state, client, session, hello, responses);
                [events addObject:@{@"event": @"gip_auth_phase", @"client": @(client), @"phase": session.auth.phase}];
            }
            state->powered[client] = YES;
            [events addObject:@{@"event": @"gip_power_on_requested", @"client": @(client)}];
        }
        if (command == 6 && (options & 32) && message && session.auth) {
            NSArray<NSData *> *messages = [session.auth receive:message];
            if (session.auth.failure) goto authFailed;
            for (NSData *authMessage in messages) appendAuth(state, client, session, authMessage, responses);
            [events addObject:@{@"event": session.auth.complete ? @"gip_auth_verified" : @"gip_auth_phase", @"client": @(client), @"phase": session.auth.phase}];
            if (session.auth.complete && !session.capabilitiesRequested) {
                // FlightStick vendor command 0x00 (device capabilities), as the Linux xbox_gip flight-stick driver sends.
                // Non-system message: options carry no 0x20 flag; empty payload.
                if (++state->sequence == 0) ++state->sequence;
                uint8_t capabilities[] = {0, client, state->sequence, 0};
                [responses addObject:[NSData dataWithBytes:capabilities length:sizeof(capabilities)]];
                session.capabilitiesRequested = YES;
                [events addObject:@{@"event": @"gip_capabilities_requested", @"client": @(client)}];
            }
        }
        if (command == 0 && !(options & 32) && message) {
            NSMutableString *hex = [NSMutableString string];
            for (NSUInteger i = 0; i < message.length; i++) [hex appendFormat:@"%02x", ((const uint8_t *)message.bytes)[i]];
            [events addObject:@{@"event": @"gip_capabilities_response", @"client": @(client), @"payload": hex}];
        }
        position += size;
        continue;
    authFailed:
        [events addObject:@{@"event": @"gip_auth_failed", @"client": @(client), @"message": session.auth.failure ?: @"Authentication setup failed"}];
        return @[];
    }
    return responses;
malformed:
    [events addObject:@{@"event": @"gip_parse_error", @"offset": @(position)}];
    return @[];
}
BOOL GIPResearchSelfTest(void) {
    GIPResearchState state = {0}; NSMutableArray *events = [NSMutableArray array];
    uint8_t announce[32] = {2, 0x20, 1, 28};
    NSArray<NSData *> *r = GIPResearchResponses(&state, [NSData dataWithBytes:announce length:32], events);
    uint8_t identify[] = {4, 0x20, 1, 0};
    if (r.count != 1 || ![r[0] isEqualToData:[NSData dataWithBytes:identify length:4]]) return NO;
    if (GIPResearchResponses(&state, [NSData dataWithBytes:announce length:32], events).count) return NO;
    uint8_t chunk[] = {4, 0xf0, 9, 2, 5, 0xaa, 0xbb};
    uint8_t ack[] = {1, 0x20, 9, 9, 0, 4, 0x20, 2, 0, 0, 0, 3, 0};
    r = GIPResearchResponses(&state, [NSData dataWithBytes:chunk length:sizeof(chunk)], events);
    if (r.count != 1 || ![r[0] isEqualToData:[NSData dataWithBytes:ack length:sizeof(ack)]]) return NO;
    uint8_t truncated[] = {2, 0x20, 1, 0x80};
    [events removeAllObjects];
    if (GIPResearchResponses(&state, [NSData dataWithBytes:truncated length:4], events).count || ![events.lastObject[@"event"] isEqual:@"gip_parse_error"]) return NO;
    uint8_t completeIdentity[36] = {4, 0x20, 10, 32};
    state.powerAfterIdentify = YES;
    r = GIPResearchResponses(&state, [NSData dataWithBytes:completeIdentity length:36], events);
    uint8_t power[] = {5, 0x20, 2, 1, 0};
    if (r.count != 1 || ![r[0] isEqualToData:[NSData dataWithBytes:power length:5]]) return NO;
    GIPResearchState completeState = {0};
    completeState.powerAfterIdentify = YES; completeState.completeAfterPower = YES;
    r = GIPResearchResponses(&completeState, [NSData dataWithBytes:completeIdentity length:36], events);
    uint8_t complete[] = {6, 0x20, 2, 2, 1, 0};
    if (r.count != 2 || ![r[1] isEqualToData:[NSData dataWithBytes:complete length:6]]) return NO;
    uint8_t shortStatus[] = {3, 0x20};
    [events removeAllObjects];
    if (GIPResearchResponses(&state, [NSData dataWithBytes:shortStatus length:2], events).count || ![events.lastObject[@"event"] isEqual:@"gip_parse_error"]) return NO;
    GIPResearchDispose(&state); GIPResearchDispose(&completeState);
    return GIPAuthSelfTest();
}
