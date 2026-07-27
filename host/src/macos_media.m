#import "macos_media.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <stdlib.h>
#include <string.h>

enum {
    WEAVER_MAX_ARTWORK_INPUT = 1024 * 1024,
    WEAVER_MAX_ARTWORK_DIMENSION = 256,
};

int weaver_macos_media_supported(void) {
    NSOperatingSystemVersion version =
        [[NSProcessInfo processInfo] operatingSystemVersion];
    return version.majorVersion > 15 ||
           (version.majorVersion == 15 && version.minorVersion >= 4);
}

int weaver_macos_automation_seam(void) {
#if defined(WEAVER_AUTOMATION_SEAM)
    return 1;
#else
    return 0;
#endif
}

int weaver_macos_normalize_artwork(const uint8_t *input, size_t input_length,
                                   uint8_t **output, size_t *output_length,
                                   uint32_t *width, uint32_t *height) {
    if (!input || input_length == 0 || input_length > WEAVER_MAX_ARTWORK_INPUT ||
        !output || !output_length || !width || !height) {
        return 0;
    }
    *output = NULL;
    *output_length = 0;
    *width = 0;
    *height = 0;

    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:input length:input_length];
        CGImageSourceRef source =
            CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source || CGImageSourceGetCount(source) == 0) {
            if (source) CFRelease(source);
            return 0;
        }
        NSDictionary *options = @{
            (NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
            (NSString *)kCGImageSourceThumbnailMaxPixelSize :
                @(WEAVER_MAX_ARTWORK_DIMENSION),
        };
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (!image) return 0;

        const size_t image_width = CGImageGetWidth(image);
        const size_t image_height = CGImageGetHeight(image);
        if (image_width == 0 || image_height == 0 ||
            image_width > WEAVER_MAX_ARTWORK_DIMENSION ||
            image_height > WEAVER_MAX_ARTWORK_DIMENSION ||
            image_width * image_height * 4 > 256 * 1024) {
            CGImageRelease(image);
            return 0;
        }

        NSMutableData *png = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
        if (!destination) {
            CGImageRelease(image);
            return 0;
        }
        CGImageDestinationAddImage(destination, image, NULL);
        const bool finalized = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(image);
        if (!finalized || png.length == 0 ||
            png.length > WEAVER_MAX_ARTWORK_INPUT) {
            return 0;
        }

        uint8_t *copy = malloc(png.length);
        if (!copy) return 0;
        memcpy(copy, png.bytes, png.length);
        *output = copy;
        *output_length = png.length;
        *width = (uint32_t)image_width;
        *height = (uint32_t)image_height;
        return 1;
    }
}

void weaver_macos_free_artwork(uint8_t *bytes) { free(bytes); }
