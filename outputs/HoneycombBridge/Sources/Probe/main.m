#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <signal.h>
#import <errno.h>

static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }
static void emit(NSDictionary *event) {
    NSMutableDictionary *line = [event mutableCopy];
    line[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:line options:NSJSONWritingSortedKeys error:NULL];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
}
static NSString *hex(NSData *data) {
    NSMutableString *s = [NSMutableString string];
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; ++i) [s appendFormat:@"%02x", b[i]];
    return s;
}
static NSDictionary *properties(io_registry_entry_t service) {
    CFMutableDictionaryRef dict = NULL;
    if (IORegistryEntryCreateCFProperties(service, &dict, kCFAllocatorDefault, 0) != KERN_SUCCESS) return @{};
    return CFBridgingRelease(dict);
}
static uint64_t registryID(io_registry_entry_t service) {
    uint64_t result = 0; IORegistryEntryGetRegistryEntryID(service, &result); return result;
}
static void dumpConfigurations(long vid, long pid) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) != KERN_SUCCESS) return;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        NSDictionary *p = properties(service);
        if ([p[@"idVendor"] longValue] != vid || [p[@"idProduct"] longValue] != pid) { IOObjectRelease(service); continue; }
        uint64_t entryID = registryID(service);
        IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
        IOReturn status = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);
        if (status != kIOReturnSuccess || !plugin) {
            emit(@{@"event": @"error", @"operation": @"usb_descriptor_plugin", @"registry_id": @(entryID), @"status": @(status)}); continue;
        }
        IOUSBDeviceInterface **usb = NULL;
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&usb);
        IODestroyPlugInInterface(plugin);
        if (query || !usb) {
            emit(@{@"event": @"error", @"operation": @"usb_descriptor_interface", @"registry_id": @(entryID), @"status": @(query)}); continue;
        }
        UInt8 selected = 0;
        IOReturn selectedStatus = (*usb)->GetConfiguration(usb, &selected);
        emit(@{@"event": @"usb_selected_configuration", @"registry_id": @(entryID), @"value": @(selected), @"status": @(selectedStatus)});
        UInt8 count = 0;
        status = (*usb)->GetNumberOfConfigurations(usb, &count);
        if (status != kIOReturnSuccess) emit(@{@"event": @"error", @"operation": @"usb_configuration_count", @"status": @(status)});
        for (UInt8 index = 0; status == kIOReturnSuccess && index < count; index++) {
            IOUSBConfigurationDescriptorPtr configuration = NULL;
            IOReturn readStatus = (*usb)->GetConfigurationDescriptorPtr(usb, index, &configuration);
            if (readStatus != kIOReturnSuccess || !configuration) {
                emit(@{@"event": @"error", @"operation": @"usb_configuration_descriptor", @"registry_id": @(entryID), @"index": @(index), @"status": @(readStatus)}); continue;
            }
            const uint8_t *bytes = (const uint8_t *)configuration;
            NSUInteger total = bytes[2] | ((NSUInteger)bytes[3] << 8);
            if (total < 9 || bytes[0] < 9) {
                emit(@{@"event": @"error", @"operation": @"malformed_usb_configuration", @"registry_id": @(entryID)}); continue;
            }
            NSMutableArray *descriptors = [NSMutableArray array];
            NSUInteger offset = 0;
            while (offset + 2 <= total) {
                NSUInteger length = bytes[offset]; uint8_t type = bytes[offset + 1];
                if (length < 2 || offset + length > total) break;
                const uint8_t *d = bytes + offset;
                NSMutableDictionary *item = [@{@"offset": @(offset), @"type": @(type), @"length": @(length)} mutableCopy];
                if (type == 4 && length >= 9) {
                    [item addEntriesFromDictionary:@{@"interface_number": @(d[2]), @"alternate_setting": @(d[3]), @"endpoint_count": @(d[4]), @"class": @(d[5]), @"subclass": @(d[6]), @"protocol": @(d[7])}];
                } else if (type == 5 && length >= 7) {
                    [item addEntriesFromDictionary:@{@"endpoint_address": @(d[2]), @"attributes": @(d[3]), @"max_packet_size": @(d[4] | ((unsigned)d[5] << 8)), @"interval": @(d[6])}];
                }
                [descriptors addObject:item]; offset += length;
            }
            emit(@{@"event": @"usb_configuration", @"registry_id": @(entryID), @"index": @(index), @"hex": hex([NSData dataWithBytes:bytes length:total]), @"descriptors": descriptors, @"parse_complete": @(offset == total)});
        }
        (*usb)->Release(usb);
    }
    IOObjectRelease(iterator);
}
static uint64_t parentUSBID(io_registry_entry_t service) {
    io_registry_entry_t current = service; IOObjectRetain(current);
    io_registry_entry_t parent = 0;
    while (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS) {
        IOObjectRelease(current); current = parent;
        if (IOObjectConformsTo(current, "IOUSBHostDevice")) {
            uint64_t found = registryID(current); IOObjectRelease(current); return found;
        }
    }
    IOObjectRelease(current); return 0;
}
static NSDictionary *usbSnapshot(long vid, long pid) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) != KERN_SUCCESS) {
        emit(@{@"event": @"error", @"operation": @"usb_enumeration"}); return snapshot;
    }
    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        NSDictionary *p = properties(service);
        if ((vid >= 0 && [p[@"idVendor"] longValue] != vid) || (pid >= 0 && [p[@"idProduct"] longValue] != pid)) {
            IOObjectRelease(service); continue;
        }
        NSMutableDictionary *device = [NSMutableDictionary dictionary];
        device[@"registry_id"] = @(registryID(service));
        io_name_t name = {0}; IORegistryEntryGetName(service, name);
        device[@"name"] = @(name);
        for (NSString *key in @[@"idVendor", @"idProduct", @"bcdDevice", @"bDeviceClass", @"bDeviceSubClass", @"bDeviceProtocol", @"locationID", @"USB Product Name", @"USB Vendor Name"]) {
            if (p[key]) device[key] = p[key];
        }
        NSMutableArray *interfaces = [NSMutableArray array];
        io_iterator_t children = 0;
        if (IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &children) == KERN_SUCCESS) {
            io_registry_entry_t child;
            while ((child = IOIteratorNext(children))) {
                if (IOObjectConformsTo(child, "IOUSBHostInterface") && parentUSBID(child) == registryID(service)) {
                    NSDictionary *cp = properties(child);
                    NSMutableDictionary *item = [NSMutableDictionary dictionaryWithObject:@(registryID(child)) forKey:@"registry_id"];
                    for (NSString *key in @[@"bInterfaceNumber", @"bAlternateSetting", @"bInterfaceClass", @"bInterfaceSubClass", @"bInterfaceProtocol", @"bNumEndpoints", @"USB Interface Name"]) {
                        if (cp[key]) item[key] = cp[key];
                    }
                    [interfaces addObject:item];
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(children);
        }
        device[@"interfaces"] = [interfaces sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"registry_id"] compare:b[@"registry_id"]];
        }];
        snapshot[[@(registryID(service)) stringValue]] = device;
        IOObjectRelease(service);
    }
    IOObjectRelease(iter); return snapshot;
}

@interface DeviceContext : NSObject
@property(nonatomic, assign) IOHIDDeviceRef device;
@property(nonatomic, strong) NSMutableDictionary *identity;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *reports;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *values;
@property(nonatomic, strong) NSMutableData *buffer;
@end
@implementation DeviceContext
@end
static NSMutableDictionary<NSNumber *, DeviceContext *> *contexts;
static DeviceContext *contextFor(IOHIDDeviceRef device) {
    return contexts[@(registryID(IOHIDDeviceGetService(device)))];
}
static void inputReport(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex length) {
    (void)sender;
    DeviceContext *c = (__bridge DeviceContext *)context;
    if (result != kIOReturnSuccess || length < 0) {
        emit(@{@"event": @"error", @"operation": @"input_report", @"status": @(result), @"device": c.identity}); return;
    }
    NSString *key = [NSString stringWithFormat:@"%d:%u", type, reportID];
    NSData *now = [NSData dataWithBytes:report length:(NSUInteger)length];
    NSData *before = c.reports[key];
    if ([before isEqualToData:now]) return;
    NSMutableArray *changes = [NSMutableArray array];
    const uint8_t *old = before.bytes;
    for (NSUInteger i = 0; i < MAX(before.length, now.length); ++i) {
        if (i >= before.length || i >= now.length || old[i] != report[i]) {
            [changes addObject:@{@"offset": @(i), @"old": i < before.length ? @(old[i]) : [NSNull null], @"new": i < now.length ? @(report[i]) : [NSNull null]}];
        }
    }
    c.reports[key] = now;
    emit(@{@"event": @"report", @"device": c.identity, @"report_type": @(type), @"report_id": @(reportID), @"length": @(length), @"hex": hex(now), @"changes": changes});
}
static void inputValue(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)context; (void)sender;
    if (result != kIOReturnSuccess) { emit(@{@"event": @"error", @"operation": @"input_value", @"status": @(result)}); return; }
    IOHIDElementRef element = IOHIDValueGetElement(value);
    DeviceContext *c = contextFor(IOHIDElementGetDevice(element));
    if (!c || IOHIDValueGetLength(value) > (CFIndex)sizeof(CFIndex)) return;
    NSNumber *cookie = @((uintptr_t)IOHIDElementGetCookie(element));
    NSNumber *n = @(IOHIDValueGetIntegerValue(value));
    if ([c.values[cookie] isEqual:n]) return;
    c.values[cookie] = n;
    emit(@{@"event": @"value", @"device": c.identity, @"cookie": cookie,
           @"usage_page": @(IOHIDElementGetUsagePage(element)), @"usage": @(IOHIDElementGetUsage(element)),
           @"report_id": @(IOHIDElementGetReportID(element)), @"value": n, @"is_relative": @((BOOL)IOHIDElementIsRelative(element)),
           @"logical_min": @(IOHIDElementGetLogicalMin(element)), @"logical_max": @(IOHIDElementGetLogicalMax(element))});
}
static void added(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)sender;
    DeviceContext *c = [DeviceContext new]; c.device = device;
    c.identity = [NSMutableDictionary dictionaryWithObject:@(registryID(IOHIDDeviceGetService(device))) forKey:@"registry_id"];
    for (NSString *key in @[@"VendorID", @"ProductID", @"Product", @"Manufacturer", @"LocationID", @"PrimaryUsagePage", @"PrimaryUsage", @"Transport"]) {
        id p = (__bridge id)IOHIDDeviceGetProperty(device, (__bridge CFStringRef)key);
        if (p) c.identity[key] = p;
    }
    c.identity[@"usb_registry_id"] = @(parentUSBID(IOHIDDeviceGetService(device)));
    c.reports = [NSMutableDictionary dictionary]; c.values = [NSMutableDictionary dictionary];
    contexts[c.identity[@"registry_id"]] = c;
    emit(@{@"event": @"hid_added", @"device": c.identity, @"status": @(result)});
    id descriptor = (__bridge id)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey));
    if ([descriptor isKindOfClass:[NSData class]]) emit(@{@"event": @"descriptor", @"device": c.identity, @"hex": hex(descriptor)});
    NSArray *elements = CFBridgingRelease(IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone));
    for (id obj in elements) {
        IOHIDElementRef e = (__bridge IOHIDElementRef)obj;
        emit(@{@"event": @"element", @"device": c.identity, @"cookie": @((uintptr_t)IOHIDElementGetCookie(e)),
               @"type": @(IOHIDElementGetType(e)), @"usage_page": @(IOHIDElementGetUsagePage(e)), @"usage": @(IOHIDElementGetUsage(e)),
               @"report_id": @(IOHIDElementGetReportID(e)), @"report_size": @(IOHIDElementGetReportSize(e)), @"report_count": @(IOHIDElementGetReportCount(e)),
               @"logical_min": @(IOHIDElementGetLogicalMin(e)), @"logical_max": @(IOHIDElementGetLogicalMax(e))});
    }
    IOReturn status = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    emit(@{@"event": @"hid_open", @"device": c.identity, @"status": @(status)});
    if (status != kIOReturnSuccess) return;
    NSNumber *max = (__bridge id)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDMaxInputReportSizeKey));
    NSInteger size = max.integerValue;
    if (size <= 0 || size > 1048576) {
        emit(@{@"event": @"error", @"device": c.identity, @"operation": @"report_buffer_size", @"size": @(size)}); return;
    }
    c.buffer = [NSMutableData dataWithLength:(NSUInteger)size];
    IOHIDDeviceRegisterInputReportCallback(device, c.buffer.mutableBytes, size, inputReport, (__bridge void *)c);
}
static void removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    DeviceContext *c = contextFor(device);
    if (!c) return;
    IOHIDDeviceRegisterInputReportCallback(device, c.buffer.mutableBytes, c.buffer.length, NULL, NULL);
    IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
    emit(@{@"event": @"hid_removed", @"device": c.identity});
    [contexts removeObjectForKey:c.identity[@"registry_id"]];
}
static long parseID(const char *s) {
    char *end = NULL; errno = 0;
    long n = strtol(s, &end, 0);
    if (errno || !*s || *end || n < 0 || n > 65535) { fprintf(stderr, "Invalid VID/PID: %s (use decimal or 0xHEX)\n", s); exit(2); }
    return n;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        long vid = -1, pid = -1; BOOL watch = NO, descriptors = NO;
        for (int i = 1; i < argc; ++i) {
            if (!strcmp(argv[i], "--watch")) watch = YES;
            else if (!strcmp(argv[i], "--descriptors")) descriptors = YES;
            else if (!strcmp(argv[i], "--vid") && i + 1 < argc) vid = parseID(argv[++i]);
            else if (!strcmp(argv[i], "--pid") && i + 1 < argc) pid = parseID(argv[++i]);
            else if (!strcmp(argv[i], "--help")) {
                puts("honeycomb-probe [--vid 0xVID --pid 0xPID] [--watch] [--descriptors]\n--descriptors requires both IDs and reads cached USB configuration descriptors without opening/configuring the device.\nWithout --watch: USB registry inventory only. --watch requires both IDs; records HID descriptors, report byte changes and values, plus USB topology changes. Ctrl-C to stop. NDJSON on stdout."); return 0;
            } else { fprintf(stderr, "Unknown/incomplete option: %s\n", argv[i]); return 2; }
        }
        if ((watch || descriptors) && (vid < 0 || pid < 0)) { fprintf(stderr, "--watch/--descriptors requires --vid and --pid from the USB inventory.\n"); return 2; }
        NSDictionary *previous = usbSnapshot(vid, pid);
        emit(@{@"event": @"inventory", @"usb_device_count": @(previous.count)});
        for (NSString *key in previous) emit(@{@"event": @"usb_added", @"device": previous[key]});
        if (descriptors) dumpConfigurations(vid, pid);
        if (!watch) return 0;
        contexts = [NSMutableDictionary dictionary];
        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        if (!manager) { fprintf(stderr, "Cannot create HID manager\n"); return 1; }
        NSDictionary *matching = @{@(kIOHIDVendorIDKey): @(vid), @(kIOHIDProductIDKey): @(pid)};
        IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)matching);
        IOHIDManagerRegisterDeviceMatchingCallback(manager, added, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removed, NULL);
        IOHIDManagerRegisterInputValueCallback(manager, inputValue, NULL);
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOReturn status = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        emit(@{@"event": @"hid_manager_open", @"status": @(status)});
        if (status != kIOReturnSuccess) { CFRelease(manager); return 1; }
        signal(SIGINT, stop); signal(SIGTERM, stop);
        double nextPoll = 0;
        emit(@{@"event": @"watch_started", @"note": @"No vendor USB requests or Xbox initialization are sent. No HID means no HID input capture; this is not a USB bus sniffer."});
        while (!stopping) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
                double now = CFAbsoluteTimeGetCurrent();
                if (now < nextPoll) continue;
                nextPoll = now + 1;
                NSDictionary *current = usbSnapshot(vid, pid);
                for (NSString *key in previous) if (!current[key]) emit(@{@"event": @"usb_removed", @"device": previous[key]});
                for (NSString *key in current) {
                    if (!previous[key]) emit(@{@"event": @"usb_added", @"device": current[key]});
                    else if (![previous[key] isEqual:current[key]]) emit(@{@"event": @"usb_changed", @"device": current[key]});
                }
                previous = current;
            }
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        for (DeviceContext *c in contexts.allValues) {
            IOHIDDeviceRegisterInputReportCallback(c.device, c.buffer.mutableBytes, c.buffer.length, NULL, NULL);
            IOHIDDeviceClose(c.device, kIOHIDOptionsTypeNone);
        }
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone); CFRelease(manager);
        [contexts removeAllObjects];
    }
    return 0;
}
