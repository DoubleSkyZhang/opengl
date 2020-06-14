
/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 The OpenGL ES view
 */

#import "OpenGLPixelBufferView.h"
#import <OpenGLES/EAGL.h>
#import <QuartzCore/CAEAGLLayer.h>
#import "ShaderUtilities.h"

#if !defined(_STRINGIFY)
#define __STRINGIFY( _x )   # _x
#define _STRINGIFY( _x )   __STRINGIFY( _x )
#endif

#define TIME_IMG_W 192
#define TIME_IMG_H 108
#define DOUBLESKY_USE_TIMESTAMP 1

static const char * kPassThruVertex = _STRINGIFY(

attribute vec4 position;
attribute mediump vec4 texturecoordinate;
varying mediump vec2 coordinate;

void main()
{
	gl_Position = position;
	coordinate = texturecoordinate.xy;
}
												 
);

static const char * kPassThruFragment = _STRINGIFY(
varying highp vec2 coordinate;
uniform sampler2D videoframe;
uniform sampler2D timeframe;
const lowp vec2 startPoint = vec2(0.3, 0.4);
const lowp vec2 timeWh = vec2(0.4, 0.2);
const highp vec3 rgb2gray = vec3(0.299, 0.587, 0.114);
void main()
{
#if DOUBLESKY_USE_TIMESTAMP
    highp vec4 result = texture2D(videoframe, coordinate);
    highp vec4 time = texture2D(timeframe, vec2((coordinate.x-startPoint.x)*1.0/timeWh.x, (coordinate.y-startPoint.y)*1.0/timeWh.y));

    lowp float showTime = step(startPoint.x, coordinate.x);
    showTime += step(startPoint.y, coordinate.y);
    showTime += step(coordinate.x, startPoint.x+timeWh.x);
    showTime += step(coordinate.y, startPoint.y+timeWh.y);

    highp float gray = dot(result.rgb, rgb2gray);

    time = mix(time, vec4(vec3(0.0), time.a), step(0.85, gray));
    time = mix(result, time, step(0.90, time.a));
    gl_FragColor = mix(result, time, step(4.0, showTime));
#else
    gl_FragColor = texture2D(videoframe, coordinate);
#endif
//    gl_FragColor = texture2D(timeframe, coordinate);
}
												   
);

enum {
	ATTRIB_VERTEX,
	ATTRIB_TEXTUREPOSITON,
	NUM_ATTRIBUTES
};

@interface OpenGLPixelBufferView ()
{
	EAGLContext *_oglContext;
	CVOpenGLESTextureCacheRef _textureCache;
	GLint _width;
	GLint _height;
	GLuint _frameBufferHandle;
	GLuint _colorBufferHandle;
	GLuint _program;
    GLint _frame, time_opengl_id;
    UIImage *test_img;
}
@end

@implementation OpenGLPixelBufferView

+ (Class)layerClass
{
	return [CAEAGLLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if ( self )
	{
        test_img = [UIImage imageNamed:@"aa.png"];
		// On iOS8 and later we use the native scale of the screen as our content scale factor.
		// This allows us to render to the exact pixel resolution of the screen which avoids additional scaling and GPU rendering work.
		// For example the iPhone 6 Plus appears to UIKit as a 736 x 414 pt screen with a 3x scale factor (2208 x 1242 virtual pixels).
		// But the native pixel dimensions are actually 1920 x 1080.
		// Since we are streaming 1080p buffers from the camera we can render to the iPhone 6 Plus screen at 1:1 with no additional scaling if we set everything up correctly.
		// Using the native scale of the screen also allows us to render at full quality when using the display zoom feature on iPhone 6/6 Plus.
		
		// Only try to compile this code if we are using the 8.0 or later SDK.
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
		if ( [UIScreen instancesRespondToSelector:@selector(nativeScale)] )
		{
			self.contentScaleFactor = [UIScreen mainScreen].nativeScale;
		}
		else
#endif
		{
			self.contentScaleFactor = [UIScreen mainScreen].scale;
		}
		
		// Initialize OpenGL ES 2
		CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
		eaglLayer.opaque = YES;
		eaglLayer.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking : @(NO),
										  kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8 };

		_oglContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
		if ( ! _oglContext ) {
			NSLog( @"Problem with OpenGL context." );
			return nil;
		}
	}
	return self;
}

- (BOOL)initializeBuffers
{
    if ([EAGLContext currentContext] != _oglContext)
        [EAGLContext setCurrentContext:_oglContext];
	BOOL success = YES;
	
	glDisable( GL_DEPTH_TEST );
	
	glGenFramebuffers( 1, &_frameBufferHandle );
	glBindFramebuffer( GL_FRAMEBUFFER, _frameBufferHandle );
	
	glGenRenderbuffers( 1, &_colorBufferHandle );
	glBindRenderbuffer( GL_RENDERBUFFER, _colorBufferHandle );
	
    [_oglContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    
	glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_width );
	glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_height );
	
	glFramebufferRenderbuffer( GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorBufferHandle );
	if ( glCheckFramebufferStatus( GL_FRAMEBUFFER ) != GL_FRAMEBUFFER_COMPLETE ) {
		NSLog( @"Failure with framebuffer generation : %d",  glCheckFramebufferStatus( GL_FRAMEBUFFER ));
		success = NO;
		goto bail;
	}
	
	//  Create a new CVOpenGLESTexture cache
	CVReturn err = CVOpenGLESTextureCacheCreate( kCFAllocatorDefault, NULL, _oglContext, NULL, &_textureCache );
	if ( err ) {
		NSLog( @"Error at CVOpenGLESTextureCacheCreate %d", err );
		success = NO;
		goto bail;
	}
	
	// attributes
	GLint attribLocation[NUM_ATTRIBUTES] = {
		ATTRIB_VERTEX, ATTRIB_TEXTUREPOSITON,
	};
	GLchar *attribName[NUM_ATTRIBUTES] = {
		"position", "texturecoordinate",
	};
	
	glueCreateProgram( kPassThruVertex, kPassThruFragment,
					  NUM_ATTRIBUTES, (const GLchar **)&attribName[0], attribLocation,
					  0, 0, 0,
					  &_program );
	
	if ( ! _program ) {
		NSLog( @"Error creating the program" );
		success = NO;
		goto bail;
	}
	
//	_frame = glGetUniformLocation(_program, "videoframe" );
    time_opengl_id = glGetUniformLocation(_program, "timeframe");
    GLenum gl_error = glGetError();
    if (gl_error != noErr)
        NSLog(@"gl_error : %d", gl_error);
    
bail:
	if ( ! success ) {
		[self reset];
	}
	return success;
}

- (void)reset
{
	EAGLContext *oldContext = [EAGLContext currentContext];
	if ( oldContext != _oglContext ) {
		if ( ! [EAGLContext setCurrentContext:_oglContext] ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Problem with OpenGL context" userInfo:nil];
			return;
		}
	}
	if ( _frameBufferHandle ) {
		glDeleteFramebuffers( 1, &_frameBufferHandle );
		_frameBufferHandle = 0;
	}
	if ( _colorBufferHandle ) {
		glDeleteRenderbuffers( 1, &_colorBufferHandle );
		_colorBufferHandle = 0;
	}
	if ( _program ) {
		glDeleteProgram( _program );
		_program = 0;
	}
	if ( _textureCache ) {
		CFRelease( _textureCache );
		_textureCache = 0;
	}
	if ( oldContext != _oglContext ) {
		[EAGLContext setCurrentContext:oldContext];
	}
}

- (void)dealloc
{
	[self reset];
}

// UIImage *img;
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
#if DOUBLESKY_USE_TIMESTAMP
    char *time_data = NULL;
//    @autoreleasepool {
        UIImage *img = [self string2image];;
        time_data = [self image2pixel:img.CGImage];
//    }
#endif

	static const GLfloat squareVertices[] = {
		-1.0f, -1.0f, // bottom left
		1.0f, -1.0f, // bottom right
		-1.0f,  1.0f, // top left
		1.0f,  1.0f, // top right
	};
	
	if ( pixelBuffer == NULL ) {
		@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"NULL pixel buffer" userInfo:nil];
		return;
	}

	EAGLContext *oldContext = [EAGLContext currentContext];
	if ( oldContext != _oglContext ) {
		if ( ! [EAGLContext setCurrentContext:_oglContext] ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Problem with OpenGL context" userInfo:nil];
			return;
		}
	}
	
	if ( _frameBufferHandle == 0 ) {
        BOOL success = [self initializeBuffers];
        if ( ! success ) {
            NSLog( @"Problem initializing OpenGL buffers." );
            return;
        }
	}
    
	// Create a CVOpenGLESTexture from a CVPixelBufferRef
	size_t frameWidth = CVPixelBufferGetWidth( pixelBuffer );
	size_t frameHeight = CVPixelBufferGetHeight( pixelBuffer );
	CVOpenGLESTextureRef texture = NULL;
	CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage( kCFAllocatorDefault, _textureCache, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RGBA, (GLsizei)frameWidth, (GLsizei)frameHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &texture);
	if ( ! texture || err ) {
		NSLog( @"CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err );
		return;
	}
    
	// Set texture parameters
    glBindTexture( CVOpenGLESTextureGetTarget( texture ), CVOpenGLESTextureGetName( texture ) );
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
	glBindTexture(GL_TEXTURE_2D, 0);
    
#if DOUBLESKY_USE_TIMESTAMP
    // doublesky_zhang
    GLuint time_texture;
    glGenTextures(1, &time_texture);
    glBindTexture(GL_TEXTURE_2D, time_texture);
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
    
    // 改为GL_REPEAT黑屏 之前也遇到过类似问题
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE ); // GL_CLAMP_TO_EDGE
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, TIME_IMG_W, TIME_IMG_H, 0, GL_RGBA, GL_UNSIGNED_BYTE, time_data);
    glBindTexture(GL_TEXTURE_2D, 0);
#endif
    
    // Set the view port to the entire view
    glBindFramebuffer(GL_FRAMEBUFFER, _frameBufferHandle);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorBufferHandle);
    GLenum checkFrameBuffer = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (checkFrameBuffer != GL_FRAMEBUFFER_COMPLETE)
        NSLog(@"checkFrameBuffer failed");
    
    glViewport( 0, 0, _width, _height );
    glClearColor(0.0, 0.0, 0.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);
    
    glUseProgram( _program );
    glActiveTexture( GL_TEXTURE0 );
    glBindTexture( CVOpenGLESTextureGetTarget( texture ), CVOpenGLESTextureGetName( texture ) );
    _frame = glGetUniformLocation(_program, "videoframe" );
    glUniform1i( _frame, 0 );
    
#if DOUBLESKY_USE_TIMESTAMP
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, time_texture);
    time_opengl_id = glGetUniformLocation(_program, "timeframe");
    glUniform1i(time_opengl_id, 1);
#endif
    glEnableVertexAttribArray( ATTRIB_VERTEX );
	glVertexAttribPointer( ATTRIB_VERTEX, 2, GL_FLOAT, 0, 0, squareVertices );
	
	// Preserve aspect ratio; fill layer bounds
	CGSize textureSamplingSize;
	CGSize cropScaleAmount = CGSizeMake( self.bounds.size.width / (float)frameWidth, self.bounds.size.height / (float)frameHeight );
	if ( cropScaleAmount.height > cropScaleAmount.width ) {
		textureSamplingSize.width = self.bounds.size.width / ( frameWidth * cropScaleAmount.height );
		textureSamplingSize.height = 1.0;
	}
	else {
		textureSamplingSize.width = 1.0;
		textureSamplingSize.height = self.bounds.size.height / ( frameHeight * cropScaleAmount.width );
	}
	
	// Perform a vertical flip by swapping the top left and the bottom left coordinate.
	// CVPixelBuffers have a top left origin and OpenGL has a bottom left origin.
	GLfloat passThroughTextureVertices[] = {
		( 1.0 - textureSamplingSize.width ) / 2.0, ( 1.0 + textureSamplingSize.height ) / 2.0, // top left
		( 1.0 + textureSamplingSize.width ) / 2.0, ( 1.0 + textureSamplingSize.height ) / 2.0, // top right
		( 1.0 - textureSamplingSize.width ) / 2.0, ( 1.0 - textureSamplingSize.height ) / 2.0, // bottom left
		( 1.0 + textureSamplingSize.width ) / 2.0, ( 1.0 - textureSamplingSize.height ) / 2.0, // bottom right
	};
	
    glEnableVertexAttribArray( ATTRIB_TEXTUREPOSITON );
	glVertexAttribPointer( ATTRIB_TEXTUREPOSITON, 2, GL_FLOAT, 0, 0, passThroughTextureVertices );
	
	glDrawArrays( GL_TRIANGLE_STRIP, 0, 4 );
    glFinish();
    
	glBindRenderbuffer( GL_RENDERBUFFER, _colorBufferHandle );
	BOOL ret = [_oglContext presentRenderbuffer:GL_RENDERBUFFER];
    if (!ret)
        NSLog(@"presentRenderbuffer failed");
	
    if (texture)
        CFRelease( texture );

#if DOUBLESKY_USE_TIMESTAMP
    glDeleteTextures(1, &time_texture);
    if (time_data)
        free(time_data);
#endif
}

- (void)flushPixelBufferCache
{
	if ( _textureCache ) {
		CVOpenGLESTextureCacheFlush(_textureCache, 0);
	}
}

#pragma mark - doublesky
- (UIImage *)string2image
{
    NSDateFormatter *format = [[NSDateFormatter alloc] init];
    format.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    
    // 开启位图时如果想要有alpha通道 参数必须指定为NO且填充clear color才能使背景alpha为0 且有时间水印的点的alpha不一定就一定是255 会跟随rgb值走 如某点rgb都是0xd5 alpha也是0xd5
    NSString *time = [format stringFromDate:[NSDate date]];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(TIME_IMG_W, TIME_IMG_H), NO, 1.0);
//    CGContextRef c = UIGraphicsGetCurrentContext();
//    CGContextSetFillColorWithColor(c, [UIColor clearColor].CGColor);
//    CGContextFillRect(c, CGRectMake(0, 0, TIME_IMG_W, TIME_IMG_H));
    
    NSDictionary *dic = @{NSFontAttributeName : [UIFont systemFontOfSize:20.0 weight:UIFontWeightHeavy], NSForegroundColorAttributeName : [UIColor whiteColor]};
//    [UIColor.whiteColor set];
    [time drawInRect:CGRectMake(0, 0, TIME_IMG_W, TIME_IMG_H) withAttributes:dic];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (char*)image2pixel:(CGImageRef)image
{
    size_t width = TIME_IMG_W; //CGImageGetWidth(image);
    size_t height = TIME_IMG_H;
    
    char *spriteData = (char*)calloc(width * height * 4, sizeof(char)); //rgba共4个byte
    // CGImageGetColorSpace(image)
    CGContextRef spriteContext = CGBitmapContextCreate(spriteData, width, height, 8, width*4, CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedLast);
    
    // 3在CGContextRef上绘图
    CGContextDrawImage(spriteContext, CGRectMake(0, 0, width, height), image);
    CGContextRelease(spriteContext);
    return spriteData;
}
@end
