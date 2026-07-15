#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum {
    WEAVER_HTTPS_OK = 0,
    WEAVER_HTTPS_INVALID_URL = 1,
    WEAVER_HTTPS_REQUEST_FAILED = 2,
    WEAVER_HTTPS_TIMED_OUT = 3,
    WEAVER_HTTPS_RESPONSE_TOO_LARGE = 4,
    WEAVER_HTTPS_CANCELLED = 5,
};

@interface WeaverHttpsDelegate : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, assign) NSUInteger responseCap;
@property(nonatomic, assign) NSInteger status;
@property(nonatomic, assign) int resultCode;
@property(nonatomic, strong) dispatch_semaphore_t completion;
@property(nonatomic, strong, nullable) NSData *testTrustedCertificate;
@property(atomic, assign) BOOL externallyCancelled;
@property(atomic, assign) BOOL deadlineExpired;
@end

@implementation WeaverHttpsDelegate

- (void)URLSession:(NSURLSession *)session
        didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
          completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *_Nullable credential))completionHandler {
    (void)session;
#if WEAVER_NETWORK_TESTING
    if (self.testTrustedCertificate &&
        [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        CFArrayRef chain = trust ? SecTrustCopyCertificateChain(trust) : NULL;
        SecCertificateRef leaf = chain && CFArrayGetCount(chain) > 0
            ? (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0)
            : NULL;
        CFDataRef leafData = leaf ? SecCertificateCopyData(leaf) : NULL;
        const BOOL matches = leafData && [(__bridge NSData *)leafData isEqualToData:self.testTrustedCertificate];
        if (leafData) CFRelease(leafData);
        if (chain) CFRelease(chain);
        if (matches) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
            return;
        }
    }
#endif
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    (void)session;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.resultCode = WEAVER_HTTPS_REQUEST_FAILED;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    self.status = ((NSHTTPURLResponse *)response).statusCode;
    const int64_t expected = response.expectedContentLength;
    if (expected > 0 && (uint64_t)expected > self.responseCap) {
        self.resultCode = WEAVER_HTTPS_RESPONSE_TOO_LARGE;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    (void)session;
    (void)task;
    (void)request;
    // Return the original 3xx to the Widget. This is intentionally stricter
    // than following same-origin redirects and makes crossing the manifest's
    // exact host boundary impossible inside the system client.
    self.status = response.statusCode;
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (self.resultCode == WEAVER_HTTPS_RESPONSE_TOO_LARGE) return;
    if (data.length > self.responseCap - self.body.length) {
        self.resultCode = WEAVER_HTTPS_RESPONSE_TOO_LARGE;
        [dataTask cancel];
        return;
    }
    [self.body appendData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *_Nullable)error {
    (void)session;
    (void)task;
    if (self.resultCode == WEAVER_HTTPS_RESPONSE_TOO_LARGE) {
        // Preserve the cap failure even though cancelling the task also
        // produces NSURLErrorCancelled.
    } else if (self.externallyCancelled) {
        self.resultCode = WEAVER_HTTPS_CANCELLED;
    } else if (self.deadlineExpired || error.code == NSURLErrorTimedOut) {
        self.resultCode = WEAVER_HTTPS_TIMED_OUT;
    } else if (error || self.status <= 0 || self.status > UINT16_MAX) {
        self.resultCode = WEAVER_HTTPS_REQUEST_FAILED;
    } else {
        self.resultCode = WEAVER_HTTPS_OK;
    }
    dispatch_semaphore_signal(self.completion);
}

@end

static NSString *_Nullable WeaverString(const uint8_t *_Nullable bytes, size_t length) {
    if (!bytes && length != 0) return nil;
    return [[NSString alloc] initWithBytes:(bytes ?: (const uint8_t *)"")
                                   length:length
                                 encoding:NSUTF8StringEncoding];
}

static int WeaverPerformHttps(const uint8_t *urlBytes,
                              size_t urlLength,
                              int method,
                              const uint8_t *headerBytes,
                              size_t headerLength,
                              const uint8_t *bodyBytes,
                              size_t bodyLength,
                              int timeoutMilliseconds,
                              size_t responseCap,
                              const uint8_t *cancelled,
                              const char *_Nullable testCertificatePath,
                              uint16_t *outStatus,
                              uint8_t **outBody,
                              size_t *outBodyLength) {
    if (!outStatus || !outBody || !outBodyLength || timeoutMilliseconds <= 0 || responseCap == 0) {
        return WEAVER_HTTPS_REQUEST_FAILED;
    }
    *outStatus = 0;
    *outBody = NULL;
    *outBodyLength = 0;

    @autoreleasepool {
        NSString *urlString = WeaverString(urlBytes, urlLength);
        NSURLComponents *components = urlString ? [NSURLComponents componentsWithString:urlString] : nil;
        if (!components || ![components.scheme.lowercaseString isEqualToString:@"https"] || components.host.length == 0) {
            return WEAVER_HTTPS_INVALID_URL;
        }
        NSURL *url = components.URL;
        if (!url) return WEAVER_HTTPS_INVALID_URL;

        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
                                                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                                timeoutInterval:(NSTimeInterval)timeoutMilliseconds / 1000.0];
        request.HTTPMethod = method == 1 ? @"POST" : @"GET";
        request.HTTPShouldHandleCookies = NO;
        if (bodyLength > 0) request.HTTPBody = [NSData dataWithBytes:bodyBytes length:bodyLength];

        NSString *headers = WeaverString(headerBytes, headerLength);
        if (!headers && headerLength != 0) return WEAVER_HTTPS_REQUEST_FAILED;
        for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
            if (line.length == 0) continue;
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound || colon.location == 0) return WEAVER_HTTPS_REQUEST_FAILED;
            NSString *name = [line substringToIndex:colon.location];
            NSString *value = [line substringFromIndex:colon.location + 1];
            if ([value hasPrefix:@" "]) value = [value substringFromIndex:1];
            [request setValue:value forHTTPHeaderField:name];
        }

        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = (NSTimeInterval)timeoutMilliseconds / 1000.0;
        configuration.timeoutIntervalForResource = (NSTimeInterval)timeoutMilliseconds / 1000.0;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

        WeaverHttpsDelegate *delegate = [[WeaverHttpsDelegate alloc] init];
        delegate.body = [[NSMutableData alloc] init];
        delegate.responseCap = responseCap;
        delegate.resultCode = WEAVER_HTTPS_REQUEST_FAILED;
        delegate.completion = dispatch_semaphore_create(0);
#if WEAVER_NETWORK_TESTING
        if (testCertificatePath) {
            NSString *path = [NSString stringWithUTF8String:testCertificatePath];
            delegate.testTrustedCertificate = path ? [NSData dataWithContentsOfFile:path] : nil;
            if (!delegate.testTrustedCertificate) return WEAVER_HTTPS_REQUEST_FAILED;
        }
#else
        (void)testCertificatePath;
#endif

        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                              delegate:delegate
                                                         delegateQueue:delegateQueue];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + (double)timeoutMilliseconds / 1000.0;
        [task resume];

        BOOL requestedStop = NO;
        while (dispatch_semaphore_wait(delegate.completion, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC)) != 0) {
            if (cancelled && __atomic_load_n(cancelled, __ATOMIC_ACQUIRE) != 0) {
                delegate.externallyCancelled = YES;
                [task cancel];
                requestedStop = YES;
                break;
            }
            if (CFAbsoluteTimeGetCurrent() >= deadline) {
                delegate.deadlineExpired = YES;
                [task cancel];
                requestedStop = YES;
                break;
            }
        }
        if (requestedStop && dispatch_semaphore_wait(delegate.completion, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) {
            [session invalidateAndCancel];
            return delegate.externallyCancelled ? WEAVER_HTTPS_CANCELLED : WEAVER_HTTPS_TIMED_OUT;
        }
        [session finishTasksAndInvalidate];

        if (delegate.resultCode != WEAVER_HTTPS_OK) return delegate.resultCode;
        *outStatus = (uint16_t)delegate.status;
        *outBodyLength = delegate.body.length;
        if (delegate.body.length > 0) {
            *outBody = malloc(delegate.body.length);
            if (!*outBody) {
                *outBodyLength = 0;
                return WEAVER_HTTPS_REQUEST_FAILED;
            }
            memcpy(*outBody, delegate.body.bytes, delegate.body.length);
        }
        return WEAVER_HTTPS_OK;
    }
}

int weaver_macos_https_perform(const uint8_t *url,
                               size_t urlLength,
                               int method,
                               const uint8_t *headers,
                               size_t headerLength,
                               const uint8_t *body,
                               size_t bodyLength,
                               int timeoutMilliseconds,
                               size_t responseCap,
                               const uint8_t *cancelled,
                               uint16_t *outStatus,
                               uint8_t **outBody,
                               size_t *outBodyLength) {
    return WeaverPerformHttps(url, urlLength, method, headers, headerLength, body, bodyLength,
                              timeoutMilliseconds, responseCap, cancelled, NULL,
                              outStatus, outBody, outBodyLength);
}

#if WEAVER_NETWORK_TESTING
int weaver_macos_https_perform_test(const uint8_t *url,
                                    size_t urlLength,
                                    int method,
                                    const uint8_t *headers,
                                    size_t headerLength,
                                    const uint8_t *body,
                                    size_t bodyLength,
                                    int timeoutMilliseconds,
                                    size_t responseCap,
                                    const uint8_t *cancelled,
                                    const char *testCertificatePath,
                                    uint16_t *outStatus,
                                    uint8_t **outBody,
                                    size_t *outBodyLength) {
    return WeaverPerformHttps(url, urlLength, method, headers, headerLength, body, bodyLength,
                              timeoutMilliseconds, responseCap, cancelled, testCertificatePath,
                              outStatus, outBody, outBodyLength);
}
#endif

void weaver_macos_https_free(void *bytes) {
    free(bytes);
}
