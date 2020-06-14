//
//  ViewController.m
//  opengl
//
//  Created by zz on 2020/6/14.
//  Copyright © 2020 zz. All rights reserved.
//

#import "ViewController.h"
#import "OpenGLPixelBufferView.h"

#import <AVFoundation/AVFoundation.h>

@interface ViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate> {
    dispatch_queue_t _sessionQueue, _videoDataOutputQueue;
    AVCaptureSession *_captureSession;
    AVCaptureDevice *_videoDevice;
    AVCaptureConnection *_videoConnection;
    OpenGLPixelBufferView *_previewView;
    AVCaptureVideoOrientation _videoBufferOrientation;
}

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    _sessionQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.session", DISPATCH_QUEUE_SERIAL );
    _videoDataOutputQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.video", DISPATCH_QUEUE_SERIAL );
    
}

- (void)viewWillAppear:(BOOL)animated {
    [self startRunning];
}

- (void)startRunning
{
    dispatch_sync( _sessionQueue, ^{
        [self setupCaptureSession];
        
        if ( _captureSession ) {
            [_captureSession startRunning];
        }
    } );
}

- (void)stopRunning
{
    dispatch_sync( _sessionQueue, ^{
        [_captureSession stopRunning];
    } );
}

- (void)setupCaptureSession
{
    if ( _captureSession ) {
        return;
    }
    
    _captureSession = [[AVCaptureSession alloc] init];
    /* Video */
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *videoDeviceError = nil;
    AVCaptureDeviceInput *videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:&videoDeviceError];
    if ( [_captureSession canAddInput:videoIn] ) {
        [_captureSession addInput:videoIn];
        _videoDevice = videoDevice;
    }
    
    AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
    videoOut.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    [videoOut setSampleBufferDelegate:self queue:_videoDataOutputQueue];
    videoOut.alwaysDiscardsLateVideoFrames = NO;
    
    if ( [_captureSession canAddOutput:videoOut] ) {
        [_captureSession addOutput:videoOut];
    }
    _videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];
        
    int frameRate;
    NSString *sessionPreset = AVCaptureSessionPresetHigh;
    CMTime frameDuration = kCMTimeInvalid;
    // For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
    if ( [NSProcessInfo processInfo].processorCount == 1 )
    {
        if ( [_captureSession canSetSessionPreset:AVCaptureSessionPreset640x480] ) {
            sessionPreset = AVCaptureSessionPreset640x480;
        }
        frameRate = 15;
    }
    else
    {

        frameRate = 30;
    }
    
    _captureSession.sessionPreset = sessionPreset;
    
    frameDuration = CMTimeMake( 1, frameRate );

    NSError *error = nil;
    if ( [videoDevice lockForConfiguration:&error] ) {
        videoDevice.activeVideoMaxFrameDuration = frameDuration;
        videoDevice.activeVideoMinFrameDuration = frameDuration;
        [videoDevice unlockForConfiguration];
    }
    else {
        NSLog( @"videoDevice lockForConfiguration returned error %@", error );
    }
    
    _videoBufferOrientation = _videoConnection.videoOrientation;
}

- (void)setupPreviewView
{
    // Set up GL view
    _previewView = [[OpenGLPixelBufferView alloc] initWithFrame:CGRectZero];
    _previewView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    
    UIInterfaceOrientation currentInterfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
    _previewView.transform = [self transformFromVideoBufferOrientationToOrientation:(AVCaptureVideoOrientation)currentInterfaceOrientation withAutoMirroring:YES]; // Front camera preview should be mirrored

    [self.view insertSubview:_previewView atIndex:0];
    CGRect bounds = CGRectZero;
    bounds.size = [self.view convertRect:self.view.bounds toView:_previewView].size;
    _previewView.bounds = bounds;
    _previewView.center = CGPointMake( self.view.bounds.size.width/2.0, self.view.bounds.size.height/2.0 );
}

// Auto mirroring: Front camera is mirrored; back camera isn't
- (CGAffineTransform)transformFromVideoBufferOrientationToOrientation:(AVCaptureVideoOrientation)orientation withAutoMirroring:(BOOL)mirror
{
    CGAffineTransform transform = CGAffineTransformIdentity;
        
    // Calculate offsets from an arbitrary reference orientation (portrait)
    CGFloat orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( orientation );
    CGFloat videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( _videoBufferOrientation );
    
    // Find the difference in angle between the desired orientation and the video orientation
    CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
    transform = CGAffineTransformMakeRotation( angleOffset );

    if ( _videoDevice.position == AVCaptureDevicePositionFront )
    {
        if ( mirror ) {
            transform = CGAffineTransformScale( transform, -1, 1 );
        }
        else {
            if ( UIInterfaceOrientationIsPortrait( (UIInterfaceOrientation)orientation ) ) {
                transform = CGAffineTransformRotate( transform, M_PI );
            }
        }
    }
    
    return transform;
}

static CGFloat angleOffsetFromPortraitOrientationToOrientation(AVCaptureVideoOrientation orientation)
{
    CGFloat angle = 0.0;
    
    switch ( orientation )
    {
        case AVCaptureVideoOrientationPortrait:
            angle = 0.0;
            break;
        case AVCaptureVideoOrientationPortraitUpsideDown:
            angle = M_PI;
            break;
        case AVCaptureVideoOrientationLandscapeRight:
            angle = -M_PI_2;
            break;
        case AVCaptureVideoOrientationLandscapeLeft:
            angle = M_PI_2;
            break;
        default:
            break;
    }
    
    return angle;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer( sampleBuffer );
    CVPixelBufferRetain(pixel);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_previewView)
            [self setupPreviewView];
        
        [self->_previewView displayPixelBuffer:pixel];
        CVPixelBufferRelease(pixel);
    });
}
@end
