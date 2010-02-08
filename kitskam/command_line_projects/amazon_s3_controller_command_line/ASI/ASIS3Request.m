//
//  ASIS3Request.m
//  Part of ASIHTTPRequest -> http://allseeing-i.com/ASIHTTPRequest
//
//  Created by Ben Copsey on 30/06/2009.
//  Copyright 2009 All-Seeing Interactive. All rights reserved.
//

#import "ASIS3Request.h"
#import <CommonCrypto/CommonHMAC.h>

NSString* const ASIS3AccessPolicyPrivate = @"private";
NSString* const ASIS3AccessPolicyPublicRead = @"public-read";
NSString* const ASIS3AccessPolicyPublicReadWrote = @"public-read-write";
NSString* const ASIS3AccessPolicyAuthenticatedRead = @"authenticated-read";

static NSString *sharedAccessKey = nil;
static NSString *sharedSecretAccessKey = nil;

// Private stuff
@interface ASIS3Request ()
	- (void)parseError;
	+ (NSData *)HMACSHA1withKey:(NSString *)key forString:(NSString *)string;
	
	@property (retain, nonatomic) NSString *currentErrorString;
@end

@implementation ASIS3Request

#pragma mark Constructors

+ (id)requestWithBucket:(NSString *)bucket path:(NSString *)path
{
	ASIS3Request *request = [[[self alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://%@.s3.amazonaws.com%@",bucket,path]]] autorelease];
	[request setBucket:bucket];
	[request setPath:path];
	return request;
}

+ (id)PUTRequestForData:(NSData *)data withBucket:(NSString *)bucket path:(NSString *)path
{
	ASIS3Request *request = [self requestWithBucket:bucket path:path];
	
	[request appendPostData:data];
	[request setRequestMethod:@"PUT"];
	return request;
}

+ (id)PUTRequestForFile:(NSString *)filePath withBucket:(NSString *)bucket path:(NSString *)path
{
	ASIS3Request *request = [self requestWithBucket:bucket path:path];
	[request setPostBodyFilePath:filePath];
	
	[request setShouldStreamPostDataFromDisk:YES];
	
	[request setRequestMethod:@"PUT"];
	[request setMimeType:[ASIHTTPRequest mimeTypeForFileAtPath:filePath]];
	return request;
}

+ (id)DELETERequestWithBucket:(NSString *)bucket path:(NSString *)path
{
	ASIS3Request *request = [self requestWithBucket:bucket path:path];
	[request setRequestMethod:@"DELETE"];
	return request;
}

+ (id)COPYRequestFromBucket:(NSString *)sourceBucket path:(NSString *)sourcePath toBucket:(NSString *)bucket path:(NSString *)path
{
	ASIS3Request *request = [self requestWithBucket:bucket path:path];
	[request setRequestMethod:@"PUT"];
	[request setSourceBucket:sourceBucket];
	[request setSourcePath:sourcePath];
	return request;
}

+ (id)HEADRequestWithBucket:(NSString *)bucket path:(NSString *)path
{
	ASIS3Request *request = [self requestWithBucket:bucket path:path];
	[request setRequestMethod:@"HEAD"];
	return request;
}

- (void)dealloc
{
	[bucket release];
	[path release];
	[dateString release];
	[mimeType release];
	[accessKey release];
	[secretAccessKey release];
	[sourcePath release];
	[sourceBucket release];
	[super dealloc];
}


- (void)setDate:(NSDate *)date
{
	NSDateFormatter *dateFormatter = [[[NSDateFormatter alloc] init] autorelease];
	// Prevent problems with dates generated by other locales (tip from: http://rel.me/t/date/)
	[dateFormatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
	[dateFormatter setDateFormat:@"EEE, d MMM yyyy HH:mm:ss Z"];
	[self setDateString:[dateFormatter stringFromDate:date]];	
}

- (ASIHTTPRequest *)HEADRequest
{
	ASIS3Request *headRequest = (ASIS3Request *)[super HEADRequest];
	[headRequest setAccessKey:[self accessKey]];
	[headRequest setSecretAccessKey:[self secretAccessKey]];
	[headRequest setPath:[self path]];
	[headRequest setBucket:[self bucket]];
	return headRequest;
}


- (void)buildRequestHeaders
{
	[super buildRequestHeaders];

	// If an access key / secret access key haven't been set for this request, let's use the shared keys
	if (![self accessKey]) {
		[self setAccessKey:[ASIS3Request sharedAccessKey]];
	}
	if (![self secretAccessKey]) {
		[self setSecretAccessKey:[ASIS3Request sharedSecretAccessKey]];
	}
	// If a date string hasn't been set, we'll create one from the current time
	if (![self dateString]) {
		[self setDate:[NSDate date]];
	}
	[self addRequestHeader:@"Date" value:[self dateString]];
	
	// Ensure our formatted string doesn't use '(null)' for the empty path
	if (![self path]) {
		[self setPath:@"/"];
	}

	NSString *canonicalizedResource = [NSString stringWithFormat:@"/%@%@",[self bucket],[self path]];
	
	// Add a header for the access policy if one was set, otherwise we won't add one (and S3 will default to private)
	NSMutableDictionary *amzHeaders = [[[NSMutableDictionary alloc] init] autorelease];
	NSString *canonicalizedAmzHeaders = @"";
	if ([self accessPolicy]) {
		[amzHeaders setObject:[self accessPolicy] forKey:@"x-amz-acl"];
	}
	if ([self sourcePath]) {
		[amzHeaders setObject:[[self sourceBucket] stringByAppendingString:[self sourcePath]] forKey:@"x-amz-copy-source"];
	}
	for (NSString *key in [amzHeaders keyEnumerator]) {
		canonicalizedAmzHeaders = [NSString stringWithFormat:@"%@%@:%@\n",canonicalizedAmzHeaders,[key lowercaseString],[amzHeaders objectForKey:key]];
		[self addRequestHeader:key value:[amzHeaders objectForKey:key]];
	}
	
	
	// Jump through hoops while eating hot food
	NSString *stringToSign;
	if ([[self requestMethod] isEqualToString:@"PUT"] && ![self sourcePath]) {
		[self addRequestHeader:@"Content-Type" value:[self mimeType]];
		stringToSign = [NSString stringWithFormat:@"PUT\n\n%@\n%@\n%@%@",[self mimeType],dateString,canonicalizedAmzHeaders,canonicalizedResource];
	} else {
		stringToSign = [NSString stringWithFormat:@"%@\n\n\n%@\n%@%@",[self requestMethod],dateString,canonicalizedAmzHeaders,canonicalizedResource];
	}
	NSString *signature = [ASIHTTPRequest base64forData:[ASIS3Request HMACSHA1withKey:[self secretAccessKey] forString:stringToSign]];
	NSString *authorizationString = [NSString stringWithFormat:@"AWS %@:%@",[self accessKey],signature];
	[self addRequestHeader:@"Authorization" value:authorizationString];
	

}


- (void)requestFinished
{
	// COPY requests return a 200 whether they succeed or fail, so we need to look at the XML to see if we were successful.
	if ([self responseStatusCode] == 200 && [self sourcePath] && [self sourceBucket]) {
		[self parseError];
		return;
	}
	if ([self responseStatusCode] < 207) {
		[super requestFinished];
		return;
	}
	[self parseError];
}

#pragma mark Error XML parsing

- (void)parseError
{
	NSXMLParser *parser = [[[NSXMLParser alloc] initWithData:[self responseData]] autorelease];
	[parser setDelegate:self];
	[parser setShouldProcessNamespaces:NO];
	[parser setShouldReportNamespacePrefixes:NO];
	[parser setShouldResolveExternalEntities:NO];
	[parser parse];

}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError
{
	[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIS3ResponseParsingFailedType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Parsing the resposnse failed",NSLocalizedDescriptionKey,parseError,NSUnderlyingErrorKey,nil]]];
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict
{
	[self setCurrentErrorString:@""];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
	if ([elementName isEqualToString:@"Message"]) {
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIS3ResponseErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[self currentErrorString],NSLocalizedDescriptionKey,nil]]];
	}
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
	[self setCurrentErrorString:[[self currentErrorString] stringByAppendingString:string]];
}

- (id)copyWithZone:(NSZone *)zone
{
	ASIS3Request *newRequest = [super copyWithZone:zone];
	[newRequest setAccessKey:[self accessKey]];
	[newRequest setSecretAccessKey:[self secretAccessKey]];
	[newRequest setBucket:[self bucket]];
	[newRequest setPath:[self path]];
	[newRequest setMimeType:[self mimeType]];
	[newRequest setAccessPolicy:[self accessPolicy]];
	[newRequest setSourceBucket:[self sourceBucket]];
	[newRequest setSourcePath:[self sourcePath]];
	return newRequest;
}


#pragma mark Shared access keys

+ (NSString *)sharedAccessKey
{
	return sharedAccessKey;
}

+ (void)setSharedAccessKey:(NSString *)newAccessKey
{
	[sharedAccessKey release];
	sharedAccessKey = [newAccessKey retain];
}

+ (NSString *)sharedSecretAccessKey
{
	return sharedSecretAccessKey;
}

+ (void)setSharedSecretAccessKey:(NSString *)newAccessKey
{
	[sharedSecretAccessKey release];
	sharedSecretAccessKey = [newAccessKey retain];
}



#pragma mark S3 Authentication helpers

// From: http://stackoverflow.com/questions/476455/is-there-a-library-for-iphone-to-work-with-hmac-sha-1-encoding

+ (NSData *)HMACSHA1withKey:(NSString *)key forString:(NSString *)string
{
	NSData *clearTextData = [string dataUsingEncoding:NSUTF8StringEncoding];
	NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
	
	uint8_t digest[CC_SHA1_DIGEST_LENGTH] = {0};
	
	CCHmacContext hmacContext;
	CCHmacInit(&hmacContext, kCCHmacAlgSHA1, keyData.bytes, keyData.length);
	CCHmacUpdate(&hmacContext, clearTextData.bytes, clearTextData.length);
	CCHmacFinal(&hmacContext, digest);
	
	return [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
}

@synthesize bucket;
@synthesize path;
@synthesize dateString;
@synthesize mimeType;
@synthesize accessKey;
@synthesize secretAccessKey;
@synthesize accessPolicy;
@synthesize currentErrorString;
@synthesize sourceBucket;
@synthesize sourcePath;
@end
