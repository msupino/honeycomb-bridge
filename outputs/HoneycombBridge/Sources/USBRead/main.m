#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <signal.h>
#import <errno.h>
#import "GIP.h"

static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }
static void emit(NSDictionary *fields) {
    NSMutableDictionary *event = [fields mutableCopy]; event[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:NULL];
    if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
}
static BOOL statusOK(NSString *operation, IOReturn status) {
    emit(@{@"event": @"usb_status", @"operation": operation, @"status": @(status), @"status_hex": [NSString stringWithFormat:@"0x%08x", status]});
    return status == kIOReturnSuccess;
}
static BOOL setAudioIdle(IOUSBDeviceInterface **device) {
    IOUSBFindInterfaceRequest request = { kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare };
    io_iterator_t iterator = 0;
    if (!statusOK(@"xone_find_audio_interface", (*device)->CreateInterfaceIterator(device, &request, &iterator))) return NO;
    io_service_t service; BOOL found = NO, ok = NO;
    while ((service = IOIteratorNext(iterator))) {
        IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
        IOReturn result = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);
        if (result != kIOReturnSuccess || !plugin) continue;
        IOUSBInterfaceInterface **audio = NULL;
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&audio);
        IODestroyPlugInInterface(plugin);
        if (query || !audio) continue;
        UInt8 number = 255;
        if ((*audio)->GetInterfaceNumber(audio, &number) == kIOReturnSuccess && number == 1) {
            found = YES;
            if (statusOK(@"xone_audio_interface_open", (*audio)->USBInterfaceOpen(audio))) {
                ok = statusOK(@"xone_audio_interface_alt_zero", (*audio)->SetAlternateInterface(audio, 0));
                if (!statusOK(@"xone_audio_interface_close", (*audio)->USBInterfaceClose(audio))) ok = NO;
            }
        }
        (*audio)->Release(audio);
        if (found) break;
    }
    IOObjectRelease(iterator);
    if (!found) emit(@{@"event": @"error", @"message": @"Expected audio interface 1 is unavailable"});
    return found && ok;
}
static long number(const char *s, long maximum) {
    char *end = NULL; errno = 0; long value = strtol(s, &end, 0);
    if (errno || !*s || *end || value < 0 || value > maximum) { fprintf(stderr, "Invalid number: %s\n", s); exit(2); }
    return value;
}
typedef struct {
    BOOL complete;
    IOReturn result;
    UInt32 length;
    uint8_t bytes[65536];
} Transfer;
static void received(void *context, IOReturn result, void *length) {
    Transfer *transfer = context; transfer->result = result;
    transfer->length = (UInt32)(uintptr_t)length; transfer->complete = YES;
}
static NSString *hex(const uint8_t *bytes, UInt32 length) {
    NSMutableString *result = [NSMutableString string];
    for (UInt32 i = 0; i < length; i++) [result appendFormat:@"%02x", bytes[i]];
    return result;
}
static BOOL transmit(IOUSBInterfaceInterface **interface, UInt8 pipe, NSData *packet) {
    Transfer *transfer = calloc(1, sizeof(Transfer));
    if (!transfer || packet.length > sizeof(transfer->bytes)) { free(transfer); return NO; }
    memcpy(transfer->bytes, packet.bytes, packet.length);
    emit(@{@"event": @"usb_tx", @"endpoint": @1, @"hex": hex(packet.bytes, (UInt32)packet.length)});
    IOReturn result = (*interface)->WritePipeAsync(interface, pipe, transfer->bytes, (UInt32)packet.length, received, transfer);
    if (result != kIOReturnSuccess) { free(transfer); return statusOK(@"gip_write_queue", result); }
    double deadline = CFAbsoluteTimeGetCurrent() + 2;
    while (!transfer->complete && !stopping && CFAbsoluteTimeGetCurrent() < deadline) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    BOOL ok = transfer->complete && statusOK(@"gip_write_completion", transfer->result);
    if (!transfer->complete) {
        statusOK(@"abort_write", (*interface)->AbortPipe(interface, pipe));
        deadline = CFAbsoluteTimeGetCurrent() + 2;
        while (!transfer->complete && CFAbsoluteTimeGetCurrent() < deadline) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    if (transfer->complete) free(transfer);
    return ok;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL xoneSetup = NO, gipIdentify = NO;
        GIPResearchState gip = {0};
        long vid = -1, pid = -1, configuration = -1, interfaceNumber = -1, endpoint = -1, seconds = 30;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--gip-authenticate")) { gip.authenticate = YES; gip.powerAfterIdentify = YES; gipIdentify = YES; xoneSetup = YES; continue; }
            if (!strcmp(argv[i], "--gip-session-complete")) { gip.completeAfterPower = YES; gip.powerAfterIdentify = YES; gipIdentify = YES; xoneSetup = YES; continue; }
            if (!strcmp(argv[i], "--gip-power-on")) { gip.powerAfterIdentify = YES; gipIdentify = YES; xoneSetup = YES; continue; }
            if (!strcmp(argv[i], "--gip-self-test")) { BOOL ok = GIPResearchSelfTest(); puts(ok ? "GIP self-tests passed" : "GIP self-tests failed"); return ok ? 0 : 1; }
            if (!strcmp(argv[i], "--gip-identify")) { gipIdentify = YES; xoneSetup = YES; continue; }
            if (!strcmp(argv[i], "--xone-setup")) { xoneSetup = YES; continue; }
            if (!strcmp(argv[i], "--help")) {
                puts("honeycomb-usb-read --vid ID --pid ID --configuration N --interface N --endpoint 0x81 [--seconds 30|0] [--xone-setup] [--gip-identify] [--gip-power-on] [--gip-session-complete] [--gip-authenticate]\n--gip-authenticate performs the source-backed challenge/key-exchange handshake and verifies the device finish; rejects mixing with experimental session-complete.\n--gip-session-complete additionally sends the xone-defined completion message experimentally; this does not perform cryptographic authentication.\n--gip-power-on additionally sends GIP power-on after completed identification; no authentication or control decoding.\n--gip-identify adds source-backed GIP identify replies and acknowledgements. It does not authenticate, power on, or decode controls.\n--xone-setup: for measured 294b:1904 configuration 1/interface 0/endpoint 0x81 only, reset USB and set interface 1 alternate 0 following xone wired startup. No GIP commands are sent.\nSelects an explicitly advertised USB configuration, opens one interface without seizure and records interrupt IN packets. Sends no vendor/Xbox commands. Attempts to restore the prior configuration on exit. Duration 1..300 seconds, or 0 to run until stopped; Ctrl-C (SIGINT) stops."); return 0;
            }
            const char *key = argv[i];
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for %s\n", key); return 2; }
            const char *value = argv[++i];
            if (!strcmp(key, "--vid")) vid = number(value, 65535);
            else if (!strcmp(key, "--pid")) pid = number(value, 65535);
            else if (!strcmp(key, "--configuration")) configuration = number(value, 255);
            else if (!strcmp(key, "--interface")) interfaceNumber = number(value, 255);
            else if (!strcmp(key, "--endpoint")) endpoint = number(value, 255);
            else if (!strcmp(key, "--seconds")) seconds = number(value, 300);
            else { fprintf(stderr, "Unknown option: %s\n", key); return 2; }
        }
        if (vid < 0 || pid < 0 || configuration < 1 || interfaceNumber < 0 || endpoint < 128 || !(endpoint & 15) || (endpoint & 0x70) || seconds < 0) {
            fprintf(stderr, "Explicit VID, PID, configuration, interface and IN endpoint are required; use --help.\n"); return 2;
        }
        if (xoneSetup && (vid != 0x294b || pid != 0x1904 || configuration != 1 || interfaceNumber != 0 || endpoint != 0x81)) {
            fprintf(stderr, "--xone-setup is limited to the measured Alpha Xbox-mode interface.\n"); return 2;
        }
        if (gip.authenticate && gip.completeAfterPower) { fprintf(stderr, "Choose authenticate or experimental session-complete, not both.\n"); return 2; }
        signal(SIGINT, stop); signal(SIGTERM, stop);
        io_iterator_t devices = 0;
        if (!statusOK(@"find_devices", IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices))) return 1;
        io_service_t selected = 0, service; unsigned matches = 0;
        while ((service = IOIteratorNext(devices))) {
            CFTypeRef v = IORegistryEntryCreateCFProperty(service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
            CFTypeRef p = IORegistryEntryCreateCFProperty(service, CFSTR("idProduct"), kCFAllocatorDefault, 0);
            if ([(__bridge id)v longValue] == vid && [(__bridge id)p longValue] == pid) {
                matches++; if (!selected) { selected = service; IOObjectRetain(selected); }
            }
            if (v) CFRelease(v); if (p) CFRelease(p); IOObjectRelease(service);
        }
        IOObjectRelease(devices);
        if (matches != 1) {
            emit(@{@"event": @"error", @"message": @"Exactly one matching USB device is required", @"matches": @(matches)});
            if (selected) IOObjectRelease(selected); return 1;
        }
        IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
        IOReturn result = IOCreatePlugInInterfaceForService(selected, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(selected);
        if (!statusOK(@"device_plugin", result) || !plugin) return 1;
        IOUSBDeviceInterface **device = NULL;
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
        IODestroyPlugInInterface(plugin);
        if (!statusOK(@"device_interface", query) || !device) return 1;
        UInt8 count = 0, previous = 0; BOOL deviceOpen = NO, changed = NO, success = NO;
        IOUSBInterfaceInterface **interface = NULL; CFRunLoopSourceRef source = NULL;
        io_iterator_t interfaces = 0; UInt8 pipe = 0, outPipe = 0; Transfer *transfer = NULL;
        if (!statusOK(@"configuration_count", (*device)->GetNumberOfConfigurations(device, &count))) goto cleanup;
        BOOL advertised = NO;
        for (UInt8 i = 0; i < count; i++) {
            IOUSBConfigurationDescriptorPtr descriptor = NULL;
            if ((*device)->GetConfigurationDescriptorPtr(device, i, &descriptor) == kIOReturnSuccess && descriptor && descriptor->bConfigurationValue == configuration) advertised = YES;
        }
        if (!advertised) { emit(@{@"event": @"error", @"message": @"Requested configuration is not advertised"}); goto cleanup; }
        if (!statusOK(@"get_configuration", (*device)->GetConfiguration(device, &previous))) goto cleanup;
        emit(@{@"event": @"prior_configuration", @"value": @(previous)});
        if (!statusOK(@"device_open", (*device)->USBDeviceOpen(device))) goto cleanup;
        deviceOpen = YES;
        if (xoneSetup && !statusOK(@"xone_usb_reset", (*device)->ResetDevice(device))) goto cleanup;
        if (previous != configuration || xoneSetup) {
            if (!statusOK(@"set_configuration", (*device)->SetConfiguration(device, (UInt8)configuration))) goto cleanup;
            changed = previous != configuration;
        }
        if (xoneSetup && !setAudioIdle(device)) goto cleanup;
        IOUSBFindInterfaceRequest request = { kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare };
        if (!statusOK(@"find_interfaces", (*device)->CreateInterfaceIterator(device, &request, &interfaces))) goto cleanup;
        while ((service = IOIteratorNext(interfaces))) {
            plugin = NULL;
            result = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
            IOObjectRelease(service);
            if (result != kIOReturnSuccess || !plugin) continue;
            IOUSBInterfaceInterface **candidate = NULL;
            query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&candidate);
            IODestroyPlugInInterface(plugin);
            if (query || !candidate) continue;
            UInt8 number = 255;
            if ((*candidate)->GetInterfaceNumber(candidate, &number) == kIOReturnSuccess && number == interfaceNumber) { interface = candidate; break; }
            (*candidate)->Release(candidate);
        }
        if (!interface) { emit(@{@"event": @"error", @"message": @"Requested interface was not published"}); goto cleanup; }
        if (!statusOK(@"interface_open", (*interface)->USBInterfaceOpen(interface))) goto cleanup;
        UInt8 endpoints = 0; UInt16 packetSize = 0;
        if (!statusOK(@"endpoint_count", (*interface)->GetNumEndpoints(interface, &endpoints))) goto cleanup;
        for (unsigned i = 1; i <= endpoints; i++) {
            UInt8 direction = 0, number = 0, type = 0, interval = 0; UInt16 size = 0;
            result = (*interface)->GetPipeProperties(interface, (UInt8)i, &direction, &number, &type, &size, &interval);
            if (result == kIOReturnSuccess && direction == kUSBIn && (0x80 | number) == endpoint && type == kUSBInterrupt && size > 0) { pipe = (UInt8)i; packetSize = size; }
            if (result == kIOReturnSuccess && direction == kUSBOut && number == 1 && type == kUSBInterrupt) outPipe = (UInt8)i;
        }
        if (gipIdentify && !outPipe) { emit(@{@"event": @"error", @"message": @"Expected interrupt OUT endpoint 1 is unavailable"}); goto cleanup; }
        if (!pipe) { emit(@{@"event": @"error", @"message": @"Requested interrupt IN endpoint was not found"}); goto cleanup; }
        if (!statusOK(@"async_source", (*interface)->CreateInterfaceAsyncEventSource(interface, &source))) goto cleanup;
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
        transfer = calloc(1, sizeof(Transfer));
        if (!transfer) goto cleanup;
        transfer->complete = YES;
        double deadline = seconds ? CFAbsoluteTimeGetCurrent() + seconds : INFINITY; unsigned packets = 0;  // --seconds 0: until stopped
        emit(@{@"event": @"raw_read_started", @"vid": @(vid), @"pid": @(pid), @"interface": @(interfaceNumber), @"endpoint": @(endpoint), @"packet_size": @(packetSize), @"seconds": @(seconds), @"note": gip.authenticate ? @"Source-backed authentication attempt; inspect gip_auth_verified or gip_auth_failed; no control mapping" : gipIdentify ? @"GIP research mode; identify/acknowledgements and optional explicit power-on/session-complete; no cryptographic authentication or control mapping" : @"No vendor-specific or Xbox initialization packets sent"});
        success = YES;
        while (!stopping && CFAbsoluteTimeGetCurrent() < deadline) {
            if (transfer->complete) {
                transfer->complete = NO;
                result = (*interface)->ReadPipeAsync(interface, pipe, transfer->bytes, packetSize, received, transfer);
                if (!statusOK(@"queue_read", result)) { transfer->complete = YES; success = NO; break; }
            }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
            if (transfer->complete) {
                if (transfer->result != kIOReturnSuccess) { statusOK(@"read_completion", transfer->result); success = NO; break; }
                if (transfer->length > packetSize) { success = NO; break; }
                emit(@{@"event": @"usb_packet", @"endpoint": @(endpoint), @"length": @(transfer->length), @"hex": hex(transfer->bytes, transfer->length)}); packets++;
                if (gipIdentify) {
                    NSMutableArray *events = [NSMutableArray array];
                    NSArray<NSData *> *responses = GIPResearchResponses(&gip, [NSData dataWithBytes:transfer->bytes length:transfer->length], events);
                    for (NSDictionary *event in events) {
                        emit(event);
                        if ([event[@"event"] isEqual:@"gip_auth_failed"]) { success = NO; stopping = 1; }
                    }
                    for (NSData *response in responses) if (!transmit(interface, outPipe, response)) { success = NO; stopping = 1; break; }
                }
            }
        }
        emit(@{@"event": @"raw_read_finished", @"packets": @(packets)});
    cleanup:
        if (transfer && !transfer->complete && interface && pipe) {
            statusOK(@"abort_read", (*interface)->AbortPipe(interface, pipe));
            double drainDeadline = CFAbsoluteTimeGetCurrent() + 2;
            while (!transfer->complete && CFAbsoluteTimeGetCurrent() < drainDeadline) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        }
        if (source) { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode); CFRelease(source); }
        if (interface) { (*interface)->USBInterfaceClose(interface); (*interface)->Release(interface); }
        if (interfaces) IOObjectRelease(interfaces);
        if (changed) { if (!statusOK(@"restore_configuration", (*device)->SetConfiguration(device, previous))) success = NO; }
        if (deviceOpen) statusOK(@"device_close", (*device)->USBDeviceClose(device));
        (*device)->Release(device);
        if (transfer && transfer->complete) free(transfer);
        GIPResearchDispose(&gip);
        return success ? 0 : 1;
    }
}
