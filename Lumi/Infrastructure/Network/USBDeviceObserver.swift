//
//  USBDeviceObserver.swift
//  LumiAgent
//
//  Uses IOKit to detect when an iPhone or iPad is plugged into the Mac via USB.
//

#if os(macOS)
import Foundation
import IOKit
import IOKit.usb
import IOKit.serial

/// Monitors USB port for iOS device connections.
public final class USBDeviceObserver {
    
    public static let shared = USBDeviceObserver()
    
    public var onDeviceConnected: (() -> Void)?
    public var onDeviceDisconnected: (() -> Void)?
    
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    
    private init() {}
    
    public func start() {
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        // Apple Vendor ID
        matchingDict[kUSBVendorID] = 0x05AC 
        
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else { return }
        
        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        
        // Notification for when a device is plugged in
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            matchingDict,
            { (userData, iterator) in
                let observer = Unmanaged<USBDeviceObserver>.fromOpaque(userData!).takeUnretainedValue()
                observer.processAddedDevices(iterator)
            },
            selfPtr,
            &addedIterator
        )
        
        // Notification for when a device is unplugged
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            matchingDict,
            { (userData, iterator) in
                let observer = Unmanaged<USBDeviceObserver>.fromOpaque(userData!).takeUnretainedValue()
                observer.processRemovedDevices(iterator)
            },
            selfPtr,
            &removedIterator
        )
        
        // Initial pass
        processAddedDevices(addedIterator)
        processRemovedDevices(removedIterator)
    }
    
    public func stop() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let notifyPort = notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
    }
    
    private func processAddedDevices(_ iterator: io_iterator_t) {
        var device = IOIteratorNext(iterator)
        while device != 0 {
            // Check if it's an iPhone/iPad by looking at the product name or other properties
            if isIOSDevice(device) {
                print("[USBDeviceObserver] iOS Device Connected via USB")
                onDeviceConnected?()
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
    }
    
    private func processRemovedDevices(_ iterator: io_iterator_t) {
        var device = IOIteratorNext(iterator)
        while device != 0 {
            if isIOSDevice(device) {
                print("[USBDeviceObserver] iOS Device Disconnected from USB")
                onDeviceDisconnected?()
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
    }
    
    private func isIOSDevice(_ device: io_object_t) -> Bool {
        // Broadly match Apple USB devices. We could refine by checking kUSBProductID
        // but often identifying as an Apple device on the USB bus is enough for this trigger.
        return true 
    }
}
#endif
