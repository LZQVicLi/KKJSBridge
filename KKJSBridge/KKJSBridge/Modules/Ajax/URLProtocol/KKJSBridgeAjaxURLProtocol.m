//
//  KKJSBridgeAjaxURLProtocol.m
//  KKJSBridge
//
//  Created by karos li on 2020/6/20.
//

#import "KKJSBridgeAjaxURLProtocol.h"
#import <CFNetwork/CFNetwork.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import "KKJSBridgeXMLBodyCacheRequest.h"
#import "KKJSBridgeURLRequestSerialization.h"
#import "KKJSBridgeFormDataFile.h"
#import "KKJSBridgeConfig.h"
#import "KKJSBridgeAjaxDelegate.h"
#import "KKJSBridgeSwizzle.h"

typedef CFHTTPMessageRef (*KKJSBridgeURLResponseGetHTTPResponse)(CFURLRef response);

static NSString * const kKKJSBridgeNSURLProtocolKey = @"kKKJSBridgeNSURLProtocolKey";
static NSString * const kKKJSBridgeRequestId = @"KKJSBridge-RequestId";
static NSString * const kKKJSBridgeOpenUrlRequestIdRegex = @"^.*#%5E%5E%5E%5E(\\d+)%5E%5E%5E%5E$";
static NSString * const kKKJSBridgeOpenUrlRequestIdHashRegex = @"^.*(#%5E%5E%5E%5E\\d+%5E%5E%5E%5E)$";
static NSString * const kKKJSBridgeAjaxRequestHeaderAC = @"Access-Control-Request-Headers";
static NSString * const kKKJSBridgeAjaxResponseHeaderAC = @"Access-Control-Allow-Headers";

@interface KKJSBridgeAjaxURLProtocol () <NSURLSessionDelegate, KKJSBridgeAjaxDelegate>

@property (nonatomic, strong) NSURLSessionDataTask *customTask;
@property (nonatomic, copy) NSString *requestId;
@property (nonatomic, copy) NSString *requestHTTPMethod;

@end

@implementation KKJSBridgeAjaxURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *acrequestHeader = headers[kKKJSBridgeAjaxRequestHeaderAC];
    /**
     1、OPTIONS请求
     2、请求头有 RequestId
     3、链接有 RequestId
     */
    if ([self validateRequestId:request.URL.absoluteString]
        || ([request.HTTPMethod isEqualToString:@"OPTIONS"] && [acrequestHeader containsString:[kKKJSBridgeRequestId lowercaseString]])
        || [headers.allKeys containsObject:kKKJSBridgeRequestId]
        || [request.URL.absoluteString containsString:kKKJSBridgeRequestId]) {
        
        // 看看是否已经处理过了，防止无限循环
        if ([NSURLProtocol propertyForKey:kKKJSBridgeNSURLProtocolKey inRequest:request]) {
            return NO;
        }
        
        return YES;
    }
  
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

- (instancetype)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)cachedResponse client:(id<NSURLProtocolClient>)client {
    self = [super initWithRequest:request cachedResponse:cachedResponse client:client];
    if (self) {
        
    }
    return self;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReqeust = [[self request] mutableCopy];
    //给我们处理过的请求设置一个标识符, 防止无限循环,
    [NSURLProtocol setProperty:@YES forKey:kKKJSBridgeNSURLProtocolKey inRequest:mutableReqeust];
    
    NSDictionary *headers = mutableReqeust.allHTTPHeaderFields;
    NSString *requestId;
    
    // 处理 OPTIONS 的情况
    NSString *acrequestHeader = headers[kKKJSBridgeAjaxRequestHeaderAC];
    if ([mutableReqeust.HTTPMethod isEqualToString:@"OPTIONS"] && [acrequestHeader containsString:[kKKJSBridgeRequestId lowercaseString]]) {
        NSMutableString *acrequestHeaderM = [acrequestHeader mutableCopy];
        [acrequestHeaderM replaceOccurrencesOfString:[NSString stringWithFormat:@",%@", [kKKJSBridgeRequestId lowercaseString]] withString:@"" options:0 range:NSMakeRange(0, acrequestHeaderM.length)];
        [acrequestHeaderM replaceOccurrencesOfString:[NSString stringWithFormat:@"%@", [kKKJSBridgeRequestId lowercaseString]] withString:@"" options:0 range:NSMakeRange(0, acrequestHeaderM.length)];
        if (acrequestHeaderM.length == 0) {
            [mutableReqeust setValue:nil forHTTPHeaderField:kKKJSBridgeAjaxRequestHeaderAC];
        } else {
            [mutableReqeust setValue:acrequestHeaderM forHTTPHeaderField:kKKJSBridgeAjaxRequestHeaderAC];
        }
    }
    
    headers = mutableReqeust.allHTTPHeaderFields;
    if ([self.class validateRequestId:mutableReqeust.URL.absoluteString]) {
        requestId = [self fetchRequestId:mutableReqeust.URL.absoluteString];
        // 移除临时的请求hash
        NSString *reqeustHash = [self fetchRequestHash:mutableReqeust.URL.absoluteString];
        NSString *absString = [mutableReqeust.URL.absoluteString stringByReplacingOccurrencesOfString:reqeustHash withString:@""];
        mutableReqeust.URL = [NSURL URLWithString:absString];
    } else if ([headers.allKeys containsObject:kKKJSBridgeRequestId]) {
        requestId = headers[kKKJSBridgeRequestId];
        // 移除临时的请求头
        [mutableReqeust setValue:nil forHTTPHeaderField:kKKJSBridgeRequestId];
    } else {
        //?KKJSBridge-RequestId=1592741662922_76828
        NSDictionary *queryParams = [self queryParams:mutableReqeust.URL.absoluteString];
        requestId = queryParams[kKKJSBridgeRequestId];
    }
    
    self.requestId = requestId;
    self.requestHTTPMethod = mutableReqeust.HTTPMethod;
    NSDictionary *bodyReqeust = [KKJSBridgeXMLBodyCacheRequest getRequestBody:requestId];
    if (bodyReqeust) {
        // 从把缓存的 body 设置给 request
        [self setBodyRequest:bodyReqeust toRequest:mutableReqeust];
    }
    
    if (KKJSBridgeConfig.ajaxDelegateManager && [KKJSBridgeConfig.ajaxDelegateManager respondsToSelector:@selector(dataTaskWithRequest:callbackDelegate:)]) {
        // 实际请求代理外部网络库处理
        self.customTask = [KKJSBridgeConfig.ajaxDelegateManager dataTaskWithRequest:mutableReqeust callbackDelegate:self];
    } else {
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:nil];
        self.customTask = [session dataTaskWithRequest:mutableReqeust];
    }
    
    [self.customTask resume];
}

- (void)stopLoading {
    if (self.customTask != nil) {
        [self.customTask  cancel];
    }
    
    [self clearRequestBody];
}

- (void)clearRequestBody {
    // 清除缓存
    if (![self.requestHTTPMethod isEqualToString:@"OPTIONS"]) {
        [KKJSBridgeXMLBodyCacheRequest deleteRequestBody:self.requestId];
    }
}

#pragma mark - NSURLSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    // 清除缓存
    [self clearRequestBody];
    
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    response = [self appendRequestIdToResponseHeader:response];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.client URLProtocol:self didLoadData:data];
}

#pragma mark - KKJSBridgeAjaxDelegate - 处理来自外部网络库的数据
- (void)JSBridgeAjax:(id<KKJSBridgeAjaxDelegate>)ajax didReceiveResponse:(NSURLResponse *)response {
    response = [self appendRequestIdToResponseHeader:response];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageAllowed];
}

- (void)JSBridgeAjax:(id<KKJSBridgeAjaxDelegate>)ajax didReceiveData:(NSData *)data {
    [self.client URLProtocol:self didLoadData:data];
}

- (void)JSBridgeAjax:(id<KKJSBridgeAjaxDelegate>)ajax didCompleteWithError:(NSError *)error {
    // 清除缓存
    [self clearRequestBody];
    
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

#pragma mark - util
/**
 
 type BodyType = "String" | "Blob" | "FormData" | "ArrayBuffer";
 
 {
    //请求唯一id
    requestId,
    //当前 href url
    requestHref,
    //请求 Url
    requestUrl,
    //body 类型
    bodyType
    //body 具体值
    value
}
*/
- (void)setBodyRequest:(NSDictionary *)bodyRequest toRequest:(NSMutableURLRequest *)request {
    NSData *data = nil;
    NSString *bodyType = bodyRequest[@"bodyType"];
    id value = bodyRequest[@"value"];
    if (!value) {
        return;
    }
    
    if ([bodyType isEqualToString:@"Blob"]) {
        data = [self dataFromBase64:value];
    } else if ([bodyType isEqualToString:@"ArrayBuffer"]) {
        data = [self dataFromBase64:value];
    } else if ([bodyType isEqualToString:@"FormData"]) {
        [self setFormData:value toRequest:request];
        return;
    } else {//String
        if ([value isKindOfClass:NSDictionary.class]) {
            // application/json
            data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        } else if ([value isKindOfClass:NSString.class]) {
            // application/x-www-form-urlencoded
            // name1=value1&name2=value2
            data = [value dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            data = value;
        }
    }
    
    request.HTTPBody = data;
}

- (NSData *)dataFromBase64:(NSString *)base64 {
    // data:image/png;base64,iVBORw0...
    NSArray<NSString *> *components = [base64 componentsSeparatedByString:@","];
    if (components.count != 2) {
        return nil;
    }
    
    NSString *splitBase64 = components.lastObject;
    NSUInteger paddedLength = splitBase64.length + (splitBase64.length % 4);
    NSString *fixBase64 = [splitBase64 stringByPaddingToLength:paddedLength withString:@"=" startingAtIndex:0];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:fixBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    
    return data;
}

- (void)setFormData:(NSDictionary *)formDataJson toRequest:(NSMutableURLRequest *)request {
    NSArray<NSString *> *fileKeys = formDataJson[@"fileKeys"];
    NSArray<NSArray *> *formData = formDataJson[@"formData"];
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSMutableArray<KKJSBridgeFormDataFile *> *fileDatas = [NSMutableArray array];
    
    for (NSArray *pair in formData) {
        if (pair.count < 2) {
            continue;
        }
        
        NSString *key = pair[0];
        if ([fileKeys containsObject:key]) {// 说明存储的是个文件数据
            NSDictionary *fileJson = pair[1];
            KKJSBridgeFormDataFile *fileData = [KKJSBridgeFormDataFile new];
            fileData.key = key;
            fileData.size = [fileJson[@"size"] unsignedIntegerValue];
            fileData.type = fileJson[@"type"];
            
            if (fileJson[@"name"] && [fileJson[@"name"] length] > 0) {
                fileData.fileName = fileJson[@"name"];
            } else {
                fileData.fileName = fileData.key;
            }
            if (fileJson[@"lastModified"] && [fileJson[@"lastModified"] unsignedIntegerValue] > 0) {
                fileData.lastModified = [fileJson[@"lastModified"] unsignedIntegerValue];
            }
            if ([fileJson[@"data"] isKindOfClass:NSString.class]) {
                NSString *base64 = (NSString *)fileJson[@"data"];
                NSData *byteData = [self dataFromBase64:base64];
                fileData.data = byteData;
            }
            
            [fileDatas addObject:fileData];
        } else {
            params[key] = pair[1];
        }
    }
    
    KKJSBridgeURLRequestSerialization *serializer = [KKJSBridgeAjaxURLProtocol urlRequestSerialization];
    [serializer multipartFormRequestWithRequest:request parameters:params constructingBodyWithBlock:^(id<KKJSBridgeMultipartFormData>  _Nonnull formData) {
        for (KKJSBridgeFormDataFile *fileData in fileDatas) {
            [formData appendPartWithFileData:fileData.data name:fileData.key fileName:fileData.fileName mimeType:fileData.type];
        }
    } error:nil];
}

#pragma mark - 响应头
- (NSURLResponse *)appendRequestIdToResponseHeader:(NSURLResponse *)response {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *res = (NSHTTPURLResponse *)response;
        NSMutableDictionary *headers = [res.allHeaderFields mutableCopy];
        if (!headers) {
            headers = [NSMutableDictionary dictionary];
        }
        
        NSMutableString *string = [headers[kKKJSBridgeAjaxResponseHeaderAC] mutableCopy];
        if (string) {
            [string appendFormat:@",%@", kKKJSBridgeRequestId];
        } else {
            string = [kKKJSBridgeRequestId mutableCopy];
        }
        headers[kKKJSBridgeAjaxResponseHeaderAC] = [string copy];
        headers[@"Access-Control-Allow-Credentials"] = @"true";
        headers[@"Access-Control-Allow-Origin"] = @"*";
        headers[@"Access-Control-Allow-Methods"] = @"OPTIONS,GET,POST,PUT,DELETE";
        
        NSHTTPURLResponse *updateRes = [[NSHTTPURLResponse alloc] initWithURL:res.URL statusCode:res.statusCode HTTPVersion:[self getHttpVersionFromResponse:res] headerFields:[headers copy]];
        response = updateRes;
    }
    
    return response;
}

- (NSString *)getHttpVersionFromResponse:(NSURLResponse *)response {
    NSString *version;
    // 获取CFURLResponseGetHTTPResponse的函数实现
    NSString *funName = @"CFURLResponseGetHTTPResponse";
    KKJSBridgeURLResponseGetHTTPResponse originURLResponseGetHTTPResponse = dlsym(RTLD_DEFAULT, [funName UTF8String]);

    SEL theSelector = NSSelectorFromString(@"_CFURLResponse");
    if ([response respondsToSelector:theSelector] &&
        NULL != originURLResponseGetHTTPResponse) {
        // 获取NSURLResponse的_CFURLResponse
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        CFTypeRef cfResponse = CFBridgingRetain([response performSelector:theSelector]);
        #pragma clang diagnostic pop
        
        if (NULL != cfResponse) {
            // 将CFURLResponseRef转化为CFHTTPMessageRef
            CFHTTPMessageRef message = originURLResponseGetHTTPResponse(cfResponse);
            // 获取http协议版本
            CFStringRef cfVersion = CFHTTPMessageCopyVersion(message);
            if (NULL != cfVersion) {
                version = (__bridge NSString *)cfVersion;
                CFRelease(cfVersion);
            }
            CFRelease(cfResponse);
        }
    }

    // 获取失败的话则设置一个默认值
    if (nil == version || ![version isKindOfClass:NSString.class] || version.length == 0) {
        version = @"HTTP/1.1";
    }

    return version;
}

#pragma mark - url 处理相关
- (NSDictionary *)queryParams:(NSString *)absoluteString {
    NSMutableDictionary *pairs = [NSMutableDictionary dictionary];
    if (NSNotFound != [absoluteString rangeOfString:@"?"].location) {
        NSString *paramString = [absoluteString substringFromIndex:
                                 ([absoluteString rangeOfString:@"?"].location + 1)];
        NSCharacterSet *delimiterSet = [NSCharacterSet characterSetWithCharactersInString:@"&"];
        NSScanner *scanner = [[NSScanner alloc] initWithString:paramString];
        while (![scanner isAtEnd]) {
            NSString* pairString = nil;
            [scanner scanUpToCharactersFromSet:delimiterSet intoString:&pairString];
            [scanner scanCharactersFromSet:delimiterSet intoString:NULL];
            NSArray *kvPair = [pairString componentsSeparatedByString:@"="];
            if (kvPair.count == 2) {
                NSString *key = [[kvPair objectAtIndex:0] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                NSString *value = [[kvPair objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                [pairs setValue:value forKey:key];
            }
        }
    }
    
    return [NSDictionary dictionaryWithDictionary:pairs];
}

- (NSString *)fetchRequestId:(NSString *)url {
    return [self fetchMatchedTextFromUrl:url withRegex:kKKJSBridgeOpenUrlRequestIdRegex];
}

- (NSString *)fetchRequestHash:(NSString *)url {
    return [self fetchMatchedTextFromUrl:url withRegex:kKKJSBridgeOpenUrlRequestIdHashRegex];
}

- (NSString *)fetchMatchedTextFromUrl:(NSString *)url withRegex:(NSString *)regexString {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:regexString options:NSRegularExpressionCaseInsensitive error:NULL];
    NSArray *matches = [regex matchesInString:url options:0 range:NSMakeRange(0, url.length)];
    NSString *content;
    for (NSTextCheckingResult *match in matches) {
        for (int i = 0; i < [match numberOfRanges]; i++) {
            //以正则中的(),划分成不同的匹配部分
            content = [url substringWithRange:[match rangeAtIndex:i]];
            if (i == 1) {
                return content;
            }
        }
    }
    
    return content;
}

+ (BOOL)validateRequestId:(NSString *)url
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", kKKJSBridgeOpenUrlRequestIdRegex];
    return [predicate evaluateWithObject:url];
}

#pragma mark - KKJSBridgeURLRequestSerialization

+ (KKJSBridgeURLRequestSerialization *)urlRequestSerialization {
    static KKJSBridgeURLRequestSerialization *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [KKJSBridgeURLRequestSerialization new];
    });
    
    return instance;
}

@end
