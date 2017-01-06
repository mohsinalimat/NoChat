//
//  NOCMTextLabel.m
//  NoChat-Example
//
//  Created by little2s on 2016/12/25.
//  Copyright © 2016年 little2s. All rights reserved.
//

#import "NOCMTextLabel.h"
#import <libkern/OSAtomic.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>

#pragma mark - NOCMSentinel

@interface NOCMSentinel : NSObject
@property (nonatomic, assign, readonly) int32_t value;
- (int32_t)increase;
@end

@implementation NOCMSentinel {
    int32_t _value;
}

- (int32_t)value
{
    return _value;
}

- (int32_t)increase
{
    return OSAtomicIncrement32(&_value);
}

@end

#pragma mark - NOCMAsyncLayer

static dispatch_queue_t NOCMAsyncLayerDisplayQueue()
{
#define MAX_QUEUE_COUNT 16
    static int queueCount;
    static dispatch_queue_t queues[MAX_QUEUE_COUNT];
    static dispatch_once_t onceToken;
    static int32_t counter = 0;
    dispatch_once(&onceToken, ^{
        queueCount = (int)[NSProcessInfo processInfo].activeProcessorCount;
        queueCount = queueCount < 1 ? 1 : queueCount > MAX_QUEUE_COUNT ? MAX_QUEUE_COUNT : queueCount;
        for (NSUInteger i = 0; i < queueCount; i++) {
            dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
            queues[i] = dispatch_queue_create("com.little2s.minimal.render", attr);
        }
    });
    int32_t cur = OSAtomicIncrement32(&counter);
    if (cur < 0) {
        cur = -cur;
    }
    return queues[(cur) % queueCount];
#undef MAX_QUEUE_COUNT
}

static dispatch_queue_t NOCMAsyncLayerReleaseQueue()
{
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
}

@interface NOCMAsyncLayerDisplayTask : NSObject

@property (nonatomic, copy) void (^willDisplay)(CALayer *layer);
@property (nonatomic, copy) void (^display)(CGContextRef context, CGSize size, BOOL(^isCancelled)(void));
@property (nonatomic, copy) void (^didDisplay)(CALayer *layer, BOOL finished);

@end

@implementation NOCMAsyncLayerDisplayTask

@end

@protocol NOCMAsyncLayerDelegate <NSObject>

@required
- (NOCMAsyncLayerDisplayTask *)newAsyncDisplayTask;

@end

@interface NOCMAsyncLayer : CALayer

@end

@implementation NOCMAsyncLayer {
    NOCMSentinel *_sentinel;
}

- (void)dealloc
{
    [_sentinel increase];
}

- (instancetype)init
{
    self = [super init];
    
    static CGFloat scale;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        scale = [UIScreen mainScreen].scale;
    });
    
    if (self) {
        self.contentsScale = scale;
        _sentinel = [[NOCMSentinel alloc] init];
    }
    return self;
}

- (void)setNeedsDisplay
{
    [self cancelAsyncDisplay];
    [super setNeedsDisplay];
}

- (void)display
{
    super.contents = super.contents;
    [self displayAsync];
}

- (void)displayAsync
{
    __strong id<NOCMAsyncLayerDelegate> delegate = (id<NOCMAsyncLayerDelegate>)self.delegate;
    NOCMAsyncLayerDisplayTask *task = [delegate newAsyncDisplayTask];
    if (!task.display) {
        if (task.willDisplay) {
            task.willDisplay(self);
        }
        self.contents = nil;
        if (task.didDisplay) {
            task.didDisplay(self, YES);
        }
        return;
    }
    
    if (task.willDisplay) {
        task.willDisplay(self);
    }
    NOCMSentinel *sentinel = _sentinel;
    int32_t value = sentinel.value;
    BOOL (^isCancelled)() = ^BOOL() {
        return value != sentinel.value;
    };
    CGSize size = self.bounds.size;
    BOOL opaque = self.opaque;
    CGFloat scale = self.contentsScale;
    CGColorRef backgroundColor = (opaque && self.backgroundColor) ? CGColorRetain(self.backgroundColor) : NULL;
    if (size.width < 1 || size.height < 1) {
        CGImageRef image = (__bridge_retained CGImageRef)(self.contents);
        self.contents = nil;
        if (image) {
            dispatch_async(NOCMAsyncLayerReleaseQueue(), ^{
                CFRelease(image);
            });
        }
        if (task.didDisplay) {
            task.didDisplay(self, YES);
        }
        CGColorRelease(backgroundColor);
        return;
    }
    
    dispatch_async(NOCMAsyncLayerDisplayQueue(), ^{
        if (isCancelled()) {
            CGColorRelease(backgroundColor);
            return;
        }
        UIGraphicsBeginImageContextWithOptions(size, opaque, scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (opaque) {
            CGContextSaveGState(context);
            {
                if (!backgroundColor || CGColorGetAlpha(backgroundColor) < 1) {
                    CGContextSetFillColorWithColor(context, [UIColor whiteColor].CGColor);
                    CGContextAddRect(context, CGRectMake(0, 0, size.width * scale, size.height * scale));
                    CGContextFillPath(context);
                }
                if (backgroundColor) {
                    CGContextSetFillColorWithColor(context, backgroundColor);
                    CGContextAddRect(context, CGRectMake(0, 0, size.width * scale, size.height * scale));
                    CGContextFillPath(context);
                }
            }
            CGContextRestoreGState(context);
            CGColorRelease(backgroundColor);
        }
        task.display(context, size, isCancelled);
        if (isCancelled()) {
            UIGraphicsEndImageContext();
            dispatch_async(dispatch_get_main_queue(), ^{
                if (task.didDisplay) {
                    task.didDisplay(self, NO);
                }
            });
            return;
        }
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (isCancelled()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (task.didDisplay) {
                    task.didDisplay(self, NO);
                }
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (isCancelled()) {
                if (task.didDisplay) {
                    task.didDisplay(self, NO);
                }
            } else {
                self.contents = (__bridge id)(image.CGImage);
                if (task.didDisplay) {
                    task.didDisplay(self, YES);
                }
            }
        });
    });
}

- (void)cancelAsyncDisplay
{
    [_sentinel increase];
}

@end

#pragma mark - NOCMTextLabel

#define kLongPressMinimumDuration 0.5
#define kLongPressAllowableMovement 9.0

static dispatch_queue_t NOCMTextLabelReleaseQueue()
{
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
}

@interface NOCMTextLabel () <NOCMAsyncLayerDelegate> {
    NSMutableAttributedString *_innerText;
    NOCMTextContainer *_innerContainer;
    NOCMTextLayout *_innerLayout;
    
    NSMutableArray *_attachmentViews;
    NSMutableArray *_attachmentLayers;
    
    NSRange _highlightRange;
    NOCMTextHighlight *_highlight;
    NOCMTextLayout *_highlightLayout;
    
    NSTimer *_longPressTimer;
    CGPoint _touchBeganPoint;
    
    struct {
        unsigned int layoutNeedUpdate : 1;
        unsigned int showingHighlight : 1;
        
        unsigned int trackingTouch : 1;
        unsigned int swallowTouch : 1;
        unsigned int touchMoved : 1;
        
        unsigned int hasTapAction : 1;
        unsigned int hasLongPressAction : 1;
    } _state;
}

@end

@implementation NOCMTextLabel

#pragma mark - Override

+ (Class)layerClass
{
    return [NOCMAsyncLayer class];
}

- (void)dealloc
{
    [_longPressTimer invalidate];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        [self commonInit];
        self.frame = frame;
    }
    return self;
}

- (void)setFrame:(CGRect)frame
{
    CGSize oldSize = self.bounds.size;
    [super setFrame:frame];
    CGSize newSize = self.bounds.size;
    if (!CGSizeEqualToSize(oldSize, newSize)) {
        _innerContainer.size = self.bounds.size;
        [self clearContents];
        [self setLayoutNeedRedraw];
    }
}

- (void)setBounds:(CGRect)bounds
{
    CGSize oldSize = self.bounds.size;
    [super setBounds:bounds];
    CGSize newSize = self.bounds.size;
    if (!CGSizeEqualToSize(oldSize, newSize)) {
        _innerContainer.size = self.bounds.size;
        [self clearContents];
        [self setLayoutNeedRedraw];
    }
}

- (CGSize)sizeThatFits:(CGSize)size
{
    return _innerLayout.textBoundingSize;
}

#pragma mark - Touches

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self updateIfNeeded];
    
    UITouch *touch = touches.anyObject;
    CGPoint point = [touch locationInView:self];
    
    _highlight = [self highlightAtPoint:point range:&_highlightRange];
    _highlightLayout = nil;
    
    if (_highlight || _tapAction || _longPressAction) {
        _touchBeganPoint = point;
        _state.trackingTouch = YES;
        _state.swallowTouch = YES;
        _state.touchMoved = NO;
        [self startLongPressTimer];
        if (_highlight) {
            [self showHighlightAnimated:NO];
        }
    } else {
        _state.trackingTouch = NO;
        _state.swallowTouch = NO;
        _state.touchMoved = NO;
    }
    
    if (!_state.swallowTouch) {
        [super touchesBegan:touches withEvent:event];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self updateIfNeeded];
    
    UITouch *touch = touches.anyObject;
    CGPoint point = [touch locationInView:self];
    
    if (_state.trackingTouch) {
        if (!_state.touchMoved) {
            CGFloat moveX = point.x - _touchBeganPoint.x;
            CGFloat moveY = point.y - _touchBeganPoint.y;
            if (fabs(moveX) > fabs(moveY)) {
                if (fabs(moveX) > kLongPressAllowableMovement) {
                    _state.touchMoved = YES;
                }
            } else {
                if (fabs(moveY) > kLongPressAllowableMovement) {
                    _state.touchMoved = YES;
                }
            }
            if (_state.touchMoved) {
                [self endLongPressTimer];
            }
        }
        if (_state.touchMoved && _highlight) {
            NOCMTextHighlight *highlight = [self highlightAtPoint:point range:nil];
            if (highlight == _highlight) {
                [self showHighlightAnimated:NO];
            } else {
                [self showHighlightAnimated:NO];
            }
        }
    }
    
    if (!_state.swallowTouch) {
        [super touchesMoved:touches withEvent:event];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    UITouch *touch = touches.anyObject;
    CGPoint point = [touch locationInView:self];
    
    if (_state.trackingTouch) {
        [self endLongPressTimer];
        if (!_state.touchMoved && _tapAction) {
            NSRange range = NSMakeRange(NSNotFound, 0);
            CGRect rect = CGRectNull;
            CGPoint point = [self convertPointToLayout:_touchBeganPoint];
            NOCMTextRange *textRange = [_innerLayout textRangeAtPoint:point];
            CGRect textRect = [_innerLayout rectForRange:textRange];
            textRect = [self convertRectFromLayout:textRect];
            if (textRange) {
                range = textRange.asRange;
                rect = textRect;
            }
            _tapAction(self, _innerText, range, rect);
        }
        if (_highlight) {
            if (!_state.touchMoved || [self highlightAtPoint:point range:nil] == _highlight) {
                NOCMTextAction tapAction = _tapAction;
                if (tapAction) {
                    NOCMTextPosition *start = [NOCMTextPosition positionWithOffset:_highlightRange.location];
                    NOCMTextPosition *end = [NOCMTextPosition positionWithOffset:_highlightRange.location + _highlightRange.length affinity:NOCMTextAffinityBackward];
                    NOCMTextRange *range = [NOCMTextRange rangeWithStart:start end:end];
                    CGRect rect = [_innerLayout rectForRange:range];
                    rect = [self convertRectFromLayout:rect];
                    tapAction(self, _innerText, _highlightRange, rect);
                }
            }
            [self removeHighlightAnimated:NO];
        }
    }
    
    if (!_state.swallowTouch) {
        [super touchesEnded:touches withEvent:event];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self endTouch];
    if (!_state.swallowTouch) {
        [super touchesCancelled:touches withEvent:event];
    }
}

#pragma mark - NOCMAsyncLayerDelegate

- (NOCMAsyncLayerDisplayTask *)newAsyncDisplayTask
{
    NSAttributedString *text = _innerText;
    NOCMTextContainer *container = _innerContainer;
    NSMutableArray *attachmentViews = _attachmentViews;
    NSMutableArray *attachmentLayers = _attachmentLayers;
    BOOL layoutNeedUpdate = _state.layoutNeedUpdate;
    __block NOCMTextLayout *layout = (_state.showingHighlight && _highlightLayout) ? _highlightLayout : _innerLayout;
    __block BOOL layoutUpdated = NO;
    if (layoutNeedUpdate) {
        text = text.copy;
        container = container.copy;
    }
    
    NOCMAsyncLayerDisplayTask *task = [[NOCMAsyncLayerDisplayTask alloc] init];
    
    task.willDisplay = ^(CALayer *layer) {
        [layer removeAnimationForKey:@"contents"];
        
        for (UIView *view in attachmentViews) {
            if (layoutNeedUpdate || ![layout.attachmentContentsSet containsObject:view]) {
                if (view.superview == self) {
                    [view removeFromSuperview];
                }
            }
        }
        for (CALayer *layer in attachmentLayers) {
            if (layoutNeedUpdate || ![layout.attachmentContentsSet containsObject:layer]) {
                if (layer.superlayer == self.layer) {
                    [layer removeFromSuperlayer];
                }
            }
        }
        [attachmentViews removeAllObjects];
        [attachmentLayers removeAllObjects];
    };
    
    task.display = ^(CGContextRef context, CGSize size, BOOL (^isCancelled)(void)) {
        if (isCancelled() || text.length == 0) {
            return;
        }
        
        NOCMTextLayout *drawLayout = layout;
        if (layoutNeedUpdate) {
            layout = [NOCMTextLayout layoutWithContainer:container text:text];
            if (isCancelled()) {
                return;
            }
            layoutUpdated = YES;
            drawLayout = layout;
        }
        
        CGSize boundingSize = drawLayout.textBoundingSize;
        CGPoint point = CGPointZero;
        [drawLayout drawInContext:context size:size point:point view:nil layer:nil cancel:isCancelled];
    };
    
    task.didDisplay = ^(CALayer *layer, BOOL finished) {
        NOCMTextLayout *drawLayout = layout;
        if (!finished) {
            for (NOCMTextAttachment *attachment in drawLayout.attachments) {
                id content = attachment.content;
                if ([content isKindOfClass:[UIView class]]) {
                    UIView *aView = (UIView *)content;
                    if (aView.superview == layer.delegate) {
                        [aView removeFromSuperview];
                    }
                } else if ([content isKindOfClass:[CALayer class]]) {
                    CALayer *aLayer = (CALayer *)content;
                    if (aLayer.superlayer == layer) {
                        [aLayer removeFromSuperlayer];
                    }
                }
            }
            return;
        }
        [layer removeAnimationForKey:@"contents"];
        
        __strong NOCMTextLabel *view = (NOCMTextLabel *)layer.delegate;
        if (!view) {
            return;
        }
        if (view->_state.layoutNeedUpdate && layoutUpdated) {
            view->_innerLayout = layout;
            view->_state.layoutNeedUpdate = NO;
        }
        
        CGSize size = layer.bounds.size;
        CGSize boundingSize = drawLayout.textBoundingSize;
        CGPoint point = CGPointZero;
        
        [drawLayout drawInContext:nil size:size point:point view:view layer:layer cancel:nil];
        for (NOCMTextAttachment *attachment in drawLayout.attachments) {
            id content = attachment.content;
            if ([content isKindOfClass:[UIView class]]) {
                [attachmentViews addObject:content];
            } else if ([content isKindOfClass:[CALayer class]]) {
                [attachmentLayers addObject:content];
            }
        }
        
    };
    
    return task;
}

#pragma mark - Setters & Getters

- (void)setTextLayout:(NOCMTextLayout *)textLayout
{
    _innerLayout = textLayout;
    _innerText = (NSMutableAttributedString *)textLayout.text;
    _innerContainer = textLayout.container;
    [self clearContents];
    _state.layoutNeedUpdate = NO;
    [self setLayoutNeedRedraw];
    [self endTouch];
    [self invalidateIntrinsicContentSize];
}

- (NOCMTextLayout *)textLayout
{
    [self updateIfNeeded];
    return _innerLayout;
}

#pragma mark - Private

- (void)commonInit
{
    
}

- (void)clearContents
{
    
}

- (void)setLayoutNeedRedraw
{
    
}

- (void)endTouch
{
    
}

- (void)updateIfNeeded
{
    
}

- (NOCMTextHighlight *)highlightAtPoint:(CGPoint)point range:(NSRangePointer)range
{
    return nil;
}

- (void)startLongPressTimer
{
    
}

- (void)showHighlightAnimated:(BOOL)animated
{
    
}

- (void)endLongPressTimer
{
    
}

- (CGPoint)convertPointToLayout:(CGPoint)point
{
    return CGPointZero;
}

- (CGRect)convertRectFromLayout:(CGRect)rect
{
    return CGRectZero;
}

- (void)removeHighlightAnimated:(BOOL)animated
{
    
}

@end

#pragma mark - NOCMTextLayout

@implementation NOCMTextLayout

+ (instancetype)layoutWithContainer:(NOCMTextContainer *)container text:(NSAttributedString *)text
{
    return [self layoutWithContainer:container text:text range:NSMakeRange(0, text.length)];
}

+ (instancetype)layoutWithContainer:(NOCMTextContainer *)container text:(NSAttributedString *)text range:(NSRange)range
{
    NOCMTextLayout *layout = [[NOCMTextLayout alloc] init];
    return layout;
}

- (NOCMTextRange *)textRangeAtPoint:(CGPoint)point
{
    return nil;
}

- (CGRect)rectForRange:(NOCMTextRange *)range
{
    return CGRectZero;
}

- (void)drawInContext:(CGContextRef)context size:(CGSize)size point:(CGPoint)point view:(UIView *)view layer:(CALayer *)layer cancel:(BOOL (^)(void))cancel
{
    
}

- (id)copyWithZone:(NSZone *)zone
{
    NOCMTextLayout *newLayout = [[NOCMTextLayout alloc] init];
    return newLayout;
}

@end

#pragma mark - NOCMTextContainer

@implementation NOCMTextContainer

+ (instancetype)containerWithSize:(CGSize)size
{
    NOCMTextContainer *container = [[NOCMTextContainer alloc] init];
    return container;
}

- (id)copyWithZone:(NSZone *)zone
{
    NOCMTextContainer *newContainer = [[NOCMTextContainer alloc] init];
    return newContainer;
}

@end

#pragma mark - NOCMTextLinePositionModifier

@implementation NOCMTextLinePositionModifier

- (CGFloat)heightForLineCount:(NSUInteger)lineCount
{
    return 0;
}

- (id)copyWithZone:(NSZone *)zone
{
    NOCMTextLinePositionModifier *modifier = [[NOCMTextLinePositionModifier alloc] init];
    return modifier;
}

@end

#pragma mark - NOCMTextHighlight

@implementation NOCMTextHighlight

@end

#pragma mark - NOCMTextPosition

@implementation NOCMTextPosition

+ (instancetype)positionWithOffset:(NSInteger)offset
{
    return nil;
}

+ (instancetype)positionWithOffset:(NSInteger)offset affinity:(NOCMTextAffinity)affinity
{
    return nil;
}

@end

#pragma mark - NOCMTextRange

@implementation NOCMTextRange

+ (instancetype)rangeWithStart:(NOCMTextPosition *)start end:(NOCMTextPosition *)end
{
    return nil;
}

- (NSRange)asRange
{
    return NSMakeRange(NSNotFound, 0);
}

@end

