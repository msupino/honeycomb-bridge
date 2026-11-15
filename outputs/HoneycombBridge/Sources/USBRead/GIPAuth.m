// SPDX-License-Identifier: GPL-2.0-or-later
// Protocol adaptation informed by xone auth/auth.c and auth/crypto.c, Copyright (C) 2023 Severin von Wnuck-Lipinski.
#import "GIPAuth.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonCrypto.h>

static NSData *randomBytes(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    return SecRandomCopyBytes(kSecRandomDefault, length, data.mutableBytes) == errSecSuccess ? data : nil;
}
static NSData *digest(NSData *data) {
    uint8_t result[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, result);
    return [NSData dataWithBytes:result length:sizeof(result)];
}
static NSData *hmac(NSData *key, NSData *data) {
    uint8_t result[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, result);
    return [NSData dataWithBytes:result length:sizeof(result)];
}
static NSData *join(NSData *first, NSData *second) {
    NSMutableData *data = [first mutableCopy]; [data appendData:second]; return data;
}
static NSData *prf(NSData *key, NSString *label, NSData *seed, NSUInteger length) {
    NSData *input = join([label dataUsingEncoding:NSUTF8StringEncoding], seed);
    NSData *a = hmac(key, input); NSMutableData *out = [NSMutableData data];
    while (out.length < length) { [out appendData:hmac(key, join(a, input))]; a = hmac(key, a); }
    return [out subdataWithRange:NSMakeRange(0, length)];
}
static uint16_t be16(const uint8_t *p) { return ((uint16_t)p[0] << 8) | p[1]; }
static void set16(uint8_t *p, NSUInteger n) { p[0] = (uint8_t)(n >> 8); p[1] = (uint8_t)n; }

@interface GIPAuth ()
@property(nonatomic) BOOL complete;
@property(nonatomic, copy) NSString *failure;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic) uint8_t lastSent;
@property(nonatomic, strong) NSData *hostRandom;
@property(nonatomic, strong) NSData *clientRandom;
@property(nonatomic, strong) NSData *master;
@property(nonatomic, strong) NSMutableData *transcript;
@end
@implementation GIPAuth
- (instancetype)init {
    if ((self = [super init])) { _transcript = [NSMutableData data]; _phase = @"not_started"; }
    return self;
}
- (NSData *)message:(uint8_t)command body:(NSData *)body {
    NSMutableData *packet = [NSMutableData dataWithLength:10 + body.length + 8]; uint8_t *p = packet.mutableBytes;
    p[1] = 0x41; p[3] = command; set16(p + 4, body.length + 4);
    p[6] = command; p[7] = command >= 0x21 ? 2 : 1; set16(p + 8, body.length);
    memcpy(p + 10, body.bytes, body.length);
    [self.transcript appendData:[packet subdataWithRange:NSMakeRange(6, body.length + 4)]];
    self.lastSent = command; return packet;
}
- (NSData *)request:(uint8_t)command size:(NSUInteger)size {
    NSMutableData *packet = [NSMutableData dataWithLength:14]; uint8_t *p = packet.mutableBytes;
    p[1] = 0x42; p[3] = command; set16(p + 4, size + 4);
    self.phase = [NSString stringWithFormat:@"request_0x%02x", command]; return packet;
}
- (NSData *)hello:(BOOL)version2 {
    self.hostRandom = randomBytes(32);
    if (!self.hostRandom) { self.failure = @"Secure random generation failed"; return nil; }
    NSMutableData *body = [self.hostRandom mutableCopy]; [body increaseLengthBy:version2 ? 4 : 8];
    self.phase = version2 ? @"host_hello_v2" : @"host_hello_v1";
    return [self message:version2 ? 0x21 : 1 body:body];
}
- (NSData *)begin { return [self hello:NO]; }
- (NSData *)finish:(BOOL)version2 {
    if (!self.master) { self.failure = @"No negotiated master secret"; return nil; }
    self.phase = @"host_finish";
    return [self message:version2 ? 0x26 : 7 body:prf(self.master, @"Host Finished", digest(self.transcript), 32)];
}
- (NSData *)rsaSecret:(NSData *)certificate {
    const uint8_t marker[] = {0x30, 0x82, 0x01, 0x0a}; NSData *keyData = nil;
    const uint8_t *p = certificate.bytes;
    for (NSUInteger i = 0; i + 270 <= certificate.length; i++) {
        if (!memcmp(p + i, marker, 4)) { keyData = [certificate subdataWithRange:NSMakeRange(i, 270)]; break; }
    }
    if (!keyData) { self.failure = @"No expected RSA public-key structure in device certificate"; return nil; }
    NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic, (__bridge id)kSecAttrKeySizeInBits: @2048};
    CFErrorRef error = NULL; SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)keyData, (__bridge CFDictionaryRef)attributes, &error);
    if (error) { CFRelease(error); error = NULL; }
    if (!key) { self.failure = @"Security framework rejected RSA public key"; return nil; }
    NSData *premaster = randomBytes(48); CFDataRef encrypted = NULL;
    if (premaster) encrypted = SecKeyCreateEncryptedData(key, kSecKeyAlgorithmRSAEncryptionPKCS1, (__bridge CFDataRef)premaster, &error);
    CFRelease(key); if (error) { CFRelease(error); error = NULL; }
    if (!encrypted) { self.failure = @"RSA key exchange failed"; return nil; }
    NSData *body = CFBridgingRelease(encrypted);
    if (body.length != 256) { self.failure = @"Unexpected RSA ciphertext size"; return nil; }
    self.master = prf(premaster, @"Master Secret", join(self.hostRandom, self.clientRandom), 48);
    self.phase = @"host_secret"; return [self message:5 body:body];
}
- (NSData *)ecdhSecret:(NSData *)publicKey {
    uint8_t prefix = 4; NSMutableData *encoded = [NSMutableData dataWithBytes:&prefix length:1]; [encoded appendData:publicKey];
    NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic, (__bridge id)kSecAttrKeySizeInBits: @256};
    CFErrorRef error = NULL;
    SecKeyRef peer = SecKeyCreateWithData((__bridge CFDataRef)encoded, (__bridge CFDictionaryRef)attributes, &error);
    if (error) { CFRelease(error); error = NULL; }
    NSDictionary *generate = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom, (__bridge id)kSecAttrKeySizeInBits: @256};
    SecKeyRef mine = peer ? SecKeyCreateRandomKey((__bridge CFDictionaryRef)generate, &error) : NULL;
    if (error) { CFRelease(error); error = NULL; }
    if (!peer || !mine) {
        if (peer) CFRelease(peer); if (mine) CFRelease(mine); self.failure = @"P-256 key creation failed"; return nil;
    }
    SecKeyRef pub = SecKeyCopyPublicKey(mine);
    CFDataRef exported = pub ? SecKeyCopyExternalRepresentation(pub, &error) : NULL;
    if (error) { CFRelease(error); error = NULL; }
    CFDataRef secret = SecKeyCopyKeyExchangeResult(mine, kSecKeyAlgorithmECDHKeyExchangeStandard, peer, (__bridge CFDictionaryRef)@{}, &error);
    CFRelease(peer); CFRelease(mine); if (pub) CFRelease(pub);
    if (error) CFRelease(error);
    NSData *hostKey = CFBridgingRelease(exported), *shared = CFBridgingRelease(secret);
    if (hostKey.length != 65 || shared.length != 32) { self.failure = @"P-256 key exchange failed"; return nil; }
    self.master = prf(digest(shared), @"Master Secret", join(self.hostRandom, self.clientRandom), 48);
    self.phase = @"host_pubkey"; return [self message:0x25 body:[hostKey subdataWithRange:NSMakeRange(1, 64)]];
}
- (NSArray<NSData *> *)receive:(NSData *)payload {
    if (self.failure || self.complete) return @[];
    const uint8_t *p = payload.bytes;
    if (payload.length < 6 || p[0] != 0 || p[2] != 0) { self.failure = @"Malformed or rejected authentication response"; return @[]; }
    NSData *response = nil;
    if (p[1] & 1) {
        if (p[3] != 1) { self.failure = @"Device rejected authentication stage"; return @[]; }
        switch (self.lastSent) {
            case 1: response = [self request:2 size:80]; break;
            case 5: response = [self finish:NO]; break;
            case 7: response = [self request:8 size:64]; break;
            case 0x21: response = [self request:0x22 size:172]; break;
            case 0x25: response = [self finish:YES]; break;
            case 0x26: response = [self request:0x27 size:64]; break;
            default: self.failure = @"Unexpected authentication acknowledgement";
        }
        return response ? @[response] : @[];
    }
    if (payload.length < 10) { self.failure = @"Truncated authentication data"; return @[]; }
    if (p[3] != p[6]) {
        [self.transcript setLength:0]; response = [self hello:YES]; return response ? @[response] : @[];
    }
    NSUInteger declared = be16(p + 8);
    if (declared > payload.length - 10 || be16(p + 4) < declared + 4) { self.failure = @"Invalid authentication data lengths"; return @[]; }
    NSData *body = [payload subdataWithRange:NSMakeRange(10, declared)];
    uint8_t command = p[6];
    if (command == 8 || command == 0x27) {
        if (body.length < 64 || !self.master) { self.failure = @"Truncated completion or missing secret"; return @[]; }
        NSData *expected = prf(self.master, @"Device Finished", digest(self.transcript), 32);
        const uint8_t *a = expected.bytes, *b = body.bytes; uint8_t difference = 0;
        for (NSUInteger i = 0; i < 32; i++) difference |= a[i] ^ b[i];
        if (difference) { self.failure = @"Device completion transcript did not verify"; return @[]; }
        [self.transcript appendData:[payload subdataWithRange:NSMakeRange(6, payload.length - 6)]];
        self.complete = YES; self.phase = @"device_finish_verified";
        uint8_t done[] = {1, 0}; return @[[NSData dataWithBytes:done length:2]];
    }
    [self.transcript appendData:[payload subdataWithRange:NSMakeRange(6, payload.length - 6)]];
    switch (command) {
        case 2:
        case 0x22:
            if (body.length < (command == 2 ? 80 : 172)) { self.failure = @"Truncated device hello"; break; }
            self.clientRandom = [body subdataWithRange:NSMakeRange(0, 32)];
            response = [self request:command == 2 ? 3 : 0x23 size:command == 2 ? 1024 : 768]; break;
        case 3:
            if (!self.clientRandom || body.length > 1024) { self.failure = @"Invalid certificate stage"; break; }
            response = [self rsaSecret:body]; break;
        case 0x23:
            if (body.length < 768) { self.failure = @"Truncated v2 device certificate"; break; }
            response = [self request:0x24 size:128]; break;
        case 0x24:
            if (body.length < 128 || !self.clientRandom) { self.failure = @"Invalid v2 key exchange stage"; break; }
            response = [self ecdhSecret:[body subdataWithRange:NSMakeRange(0, 64)]]; break;
        default: self.failure = @"Unsupported authentication command";
    }
    return response ? @[response] : @[];
}
@end
BOOL GIPAuthSelfTest(void) {
    NSMutableData *key = [NSMutableData dataWithLength:20]; memset(key.mutableBytes, 0x0b, 20);
    const uint8_t expected[] = {0xb0,0x34,0x4c,0x61,0xd8,0xdb,0x38,0x53,0x5c,0xa8,0xaf,0xce,0xaf,0x0b,0xf1,0x2b,0x88,0x1d,0xc2,0x00,0xc9,0x83,0x3d,0xa7,0x26,0xe9,0x37,0x6c,0x2e,0x32,0xcf,0xf7};
    if (![hmac(key, [@"Hi There" dataUsingEncoding:NSUTF8StringEncoding]) isEqualToData:[NSData dataWithBytes:expected length:32]]) return NO;
    GIPAuth *auth = [GIPAuth new]; NSData *hello = [auth begin];
    if (hello.length != 58 || auth.complete || auth.failure) return NO;
    uint8_t ack[] = {0, 0xc1, 0, 1, 0, 0};
    NSArray<NSData *> *r = [auth receive:[NSData dataWithBytes:ack length:6]];
    uint8_t request[] = {0, 0x42, 0, 2, 0, 84, 0, 0, 0, 0, 0, 0, 0, 0};
    if (r.count != 1 || ![r[0] isEqualToData:[NSData dataWithBytes:request length:14]]) return NO;
    GIPAuth *bad = [GIPAuth new]; [bad begin]; uint8_t invalid[] = {0, 0xc1, 1, 1, 0, 0};
    if ([bad receive:[NSData dataWithBytes:invalid length:6]].count || !bad.failure || bad.complete) return NO;
    GIPAuth *forged = [GIPAuth new];
    forged.master = [NSMutableData dataWithLength:48];
    NSMutableData *finish = [NSMutableData dataWithLength:74];
    uint8_t *f = finish.mutableBytes; f[3] = 8; set16(f + 4, 68); f[6] = 8; f[7] = 1; set16(f + 8, 64);
    if ([forged receive:finish].count || !forged.failure || forged.complete) return NO;
    return YES;
}
