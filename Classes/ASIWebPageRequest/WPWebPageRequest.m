//
//  WPWebPageRequest.m
//  Wiki
//
//  Created by Evan on 5/18/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//
#import "JSONKit.h"
#import "WPWebPageRequest.h"

static xmlChar *xpathExpr = (xmlChar *)"//img/@src";

static NSLock *xmlParsingLock = nil;
static NSMutableArray *requestsUsingXMLParser = nil;

@implementation WPWebPageRequest


- (void)readResourceURLs
{
	// Create xpath evaluation context
    xmlXPathContextPtr xpathCtx = xmlXPathNewContext(doc);
    if(xpathCtx == NULL) {
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:101 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Error: unable to create new XPath context",NSLocalizedDescriptionKey,nil]]];
		return;
    }
    
    // Evaluate xpath expression
    xmlXPathObjectPtr xpathObj = xmlXPathEvalExpression(xpathExpr, xpathCtx);
    if(xpathObj == NULL) {
        xmlXPathFreeContext(xpathCtx); 
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:101 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Error: unable to evaluate XPath expression!",NSLocalizedDescriptionKey,nil]]];
		return;
    }
	
	// Now loop through our matches
	xmlNodeSetPtr nodes = xpathObj->nodesetval;
    
    int size = (nodes) ? nodes->nodeNr : 0;
	int i;
    for(i = size - 1; i >= 0; i--) {
		assert(nodes->nodeTab[i]);
		NSString *parentName  = [NSString stringWithCString:(char *)nodes->nodeTab[i]->parent->name encoding:[self responseEncoding]];
		NSString *nodeName = [NSString stringWithCString:(char *)nodes->nodeTab[i]->name encoding:[self responseEncoding]];
        
		xmlChar *nodeValue = xmlNodeGetContent(nodes->nodeTab[i]);
		NSString *value = [NSString stringWithCString:(char *)nodeValue encoding:[self responseEncoding]];
		xmlFree(nodeValue);
        
		// Our xpath query matched all <link> elements, but we're only interested in stylesheets
		// We do the work here rather than in the xPath query because the query is case-sensitive, and we want to match on 'stylesheet', 'StyleSHEEt' etc
		if ([[parentName lowercaseString] isEqualToString:@"link"]) {
			xmlChar *relAttribute = xmlGetNoNsProp(nodes->nodeTab[i]->parent,(xmlChar *)"rel");
			if (relAttribute) {
				NSString *rel = [NSString stringWithCString:(char *)relAttribute encoding:[self responseEncoding]];
				xmlFree(relAttribute);
				if ([[rel lowercaseString] isEqualToString:@"stylesheet"]) {
					[self addURLToFetch:value];
				}
			}
            
            // Parse the content of <style> tags and style attributes to find external image urls or external css files
		} else if ([[nodeName lowercaseString] isEqualToString:@"style"]) {
			NSArray *externalResources = [[self class] CSSURLsFromString:value];
			for (NSString *theURL in externalResources) {
				[self addURLToFetch:theURL];
			}
            
            // Parse the content of <source src=""> tags (HTML 5 audio + video)
            // We explictly disable the download of files with .webm, .ogv and .ogg extensions, since it's highly likely they won't be useful to us
		} else if ([[parentName lowercaseString] isEqualToString:@"source"] || [[parentName lowercaseString] isEqualToString:@"audio"]) {
			NSString *fileExtension = [[value pathExtension] lowercaseString];
			if (![fileExtension isEqualToString:@"ogg"] && ![fileExtension isEqualToString:@"ogv"] && ![fileExtension isEqualToString:@"webm"]) {
				[self addURLToFetch:value];
			}
            
            // For all other elements matched by our xpath query (except hyperlinks), add the content as an external url to fetch
		} else if (![[parentName lowercaseString] isEqualToString:@"a"]) {
			[self addURLToFetch:value];
		}
		if (nodes->nodeTab[i]->type != XML_NAMESPACE_DECL) {
			nodes->nodeTab[i] = NULL;
		}
    }
	
	xmlXPathFreeObject(xpathObj);
    xmlXPathFreeContext(xpathCtx); 
}


- (void)parseAsHTML
{
	webContentType = ASIHTMLWebContentType;
    
	// Only allow parsing of a single document at a time
	[xmlParsingLock lock];
    
	if (![requestsUsingXMLParser count]) {
		xmlInitParser();
	}
	[requestsUsingXMLParser addObject:self];
    
    
    /* Load XML document */
    
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:[self downloadDestinationPath]];
    data = [NSMutableData dataWithData:[data gzipInflate]];
    char null = '\0';
    [data appendBytes:&null length:sizeof(char)];
    NSError *err;
    NSDictionary *obj = (NSDictionary*)[data mutableObjectFromJSONDataWithParseOptions:JKParseOptionPermitTextAfterValidJSON error:&err];
    NSString *article = [obj objectForKey:@"body"];
	
    doc = htmlReadMemory([article cStringUsingEncoding:NSUTF8StringEncoding], [article lengthOfBytesUsingEncoding:NSUTF8StringEncoding], NULL, [self encodingName], HTML_PARSE_NONET | HTML_PARSE_NOWARNING | HTML_PARSE_NOERROR);
    if (doc == NULL) {
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:101 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Error: unable to parse reponse XML",NSLocalizedDescriptionKey,nil]]];
		return;
    }
	
	[self setResourceList:[NSMutableDictionary dictionary]];
    
    // Populate the list of URLS to download
    [self readResourceURLs];
    
	if ([self error] || ![[self resourceList] count]) {
		[requestsUsingXMLParser removeObject:self];
		xmlFreeDoc(doc);
		doc = NULL;
	}
    
	[xmlParsingLock unlock];
    
	if ([self error]) {
		return;
	} else if (![[self resourceList] count]) {
		[super requestFinished];
		[super markAsFinished];
		return;
	}
	
	// Create a new request for every item in the queue
	[[self externalResourceQueue] cancelAllOperations];
	[self setExternalResourceQueue:[ASINetworkQueue queue]];
	[[self externalResourceQueue] setDelegate:self];
	[[self externalResourceQueue] setShowAccurateProgress:[self showAccurateProgress]];
	[[self externalResourceQueue] setQueueDidFinishSelector:@selector(finishedFetchingExternalResources:)];
	[[self externalResourceQueue] setRequestDidFinishSelector:@selector(externalResourceFetchSucceeded:)];
	[[self externalResourceQueue] setRequestDidFailSelector:@selector(externalResourceFetchFailed:)];
	for (NSString *theURL in [[self resourceList] keyEnumerator]) {
		ASIWebPageRequest *externalResourceRequest = [ASIWebPageRequest requestWithURL:[NSURL URLWithString:theURL relativeToURL:[self url]]];
		[externalResourceRequest setRequestHeaders:[self requestHeaders]];
		[externalResourceRequest setDownloadCache:[self downloadCache]];
		[externalResourceRequest setCachePolicy:[self cachePolicy]];
		[externalResourceRequest setCacheStoragePolicy:[self cacheStoragePolicy]];
		[externalResourceRequest setUserInfo:[NSDictionary dictionaryWithObject:theURL forKey:@"Path"]];
		[externalResourceRequest setParentRequest:self];
		[externalResourceRequest setUrlReplacementMode:[self urlReplacementMode]];
		[externalResourceRequest setShouldResetDownloadProgress:NO];
		[externalResourceRequest setDelegate:self];
		[externalResourceRequest setUploadProgressDelegate:self];
		[externalResourceRequest setDownloadProgressDelegate:self];
		[externalResourceRequest setDownloadDestinationPath:[IMAGE_DIR stringByAppendingPathComponent:[theURL lastPathComponent]]];
		[[self externalResourceQueue] addOperation:externalResourceRequest];
	}
	[[self externalResourceQueue] go];
}

@end
