//
//  TLYShyNavBarManager.m
//  TLYShyNavBarDemo
//
//  Created by Mazyad Alabduljaleel on 6/13/14.
//  Copyright (c) 2014 Telly, Inc. All rights reserved.
//

#import "TLYShyNavBarManager.h"

#import "ShyControllers/TLYShyViewController.h"
#import "ShyControllers/TLYShyStatusBarController.h"
#import "ShyControllers/TLYShyScrollViewController.h"

#import "Categories/TLYDelegateProxy.h"
#import "Categories/UIViewController+BetterLayoutGuides.h"
#import "Categories/NSObject+TLYSwizzlingHelpers.h"
#import "Categories/UIScrollView+Helpers.h"

#import <objc/runtime.h>


#pragma mark - TLYShyNavBarManager class

@interface TLYShyNavBarManager () <UIScrollViewDelegate, TLYShyViewControllerDelegate>

@property (nonatomic, strong) TLYShyStatusBarController *statusBarController;
@property (nonatomic, strong) TLYShyViewController *navBarController;
@property (nonatomic, strong) TLYShyViewController *extensionController;
@property (nonatomic, strong) TLYShyScrollViewController *scrollViewController;

@property (nonatomic, strong) TLYDelegateProxy *delegateProxy;

@property (nonatomic, strong) UIView *extensionViewContainer;

@property (nonatomic, assign) CGFloat previousYOffset;
@property (nonatomic, assign) CGFloat resistanceConsumed;

@property (nonatomic, readonly) CGFloat bottom;
@property (nonatomic, assign) BOOL scrolling;
@property (nonatomic, assign) BOOL contracting;
@property (nonatomic, assign) BOOL previousContractionState;

@property (nonatomic, readonly) BOOL isViewControllerVisible;
@property (nonatomic, readonly) BOOL isMidTransition;

@end

@implementation TLYShyNavBarManager

#pragma mark - Init & Dealloc

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        self.delegateProxy = [[TLYDelegateProxy alloc] initWithMiddleMan:self];

        /* Initialize defaults */
        self.scrolling = NO;
        self.contracting = NO;
        self.previousContractionState = YES;
        self.scaleBehavior = YES;
        self.fadeBehavior = TLYShyNavBarFadeSubviews;
        self.expansionResistance = 200.f;
        self.contractionResistance = 0.f;
        self.previousYOffset = NAN;

        /* Initialize shy controllers */
        self.statusBarController = [[TLYShyStatusBarController alloc] init];
        self.scrollViewController = [[TLYShyScrollViewController alloc] init];
        
        self.navBarController = [[TLYShyViewController alloc] init];
        self.navBarController.delegate = self;

        self.extensionViewContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100.f, 0.f)];
        self.extensionViewContainer.backgroundColor = [UIColor clearColor];
        self.extensionViewContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleBottomMargin;

        self.extensionController = [[TLYShyViewController alloc] init];
        self.extensionController.view = self.extensionViewContainer;
        self.extensionController.delegate = self;

        /* hierarchy setup */
        /* StatusBar <--> navBar <--> extensionView <--> scrollView
         */
        self.navBarController.parent = self.statusBarController;
        self.navBarController.child = self.extensionController;
        self.navBarController.subShyController = self.extensionController;
        self.extensionController.parent = self.navBarController;
        self.extensionController.child = self.scrollViewController;
        self.scrollViewController.parent = self.extensionController;

        /* Notification helpers */
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    // sanity check
    if (_scrollView.delegate == _delegateProxy)
    {
        _scrollView.delegate = _delegateProxy.originalDelegate;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Properties

- (void)setViewController:(UIViewController *)viewController
{
    _viewController = viewController;

    if ([viewController isKindOfClass:[UITableViewController class]]
        || [viewController.view isKindOfClass:[UITableViewController class]])
    {
        NSLog(@"*** WARNING: Please consider using a UIViewController with a UITableView as a subview ***");
    }

    UIView *navbar = viewController.navigationController.navigationBar;
    NSAssert(navbar != nil, @"Please make sure the viewController is already attached to a navigation controller.");

    viewController.extendedLayoutIncludesOpaqueBars = YES;

    [self.extensionViewContainer removeFromSuperview];
    [self.viewController.view addSubview:self.extensionViewContainer];

    self.navBarController.view = navbar;
}

- (void)setScrollView:(UIScrollView *)scrollView
{
    if (_scrollView.delegate == self.delegateProxy)
    {
        _scrollView.delegate = self.delegateProxy.originalDelegate;
    }

    _scrollView = scrollView;
    self.scrollViewController.scrollView = scrollView;

    NSUInteger index = [scrollView.subviews indexOfObjectPassingTest:^BOOL (id obj, NSUInteger idx, BOOL *stop) {
        return [obj isKindOfClass:[UIRefreshControl class]];
    }];

    if (index != NSNotFound) {
        self.scrollViewController.refreshControl = [scrollView.subviews objectAtIndex:index];
    }

    if (_scrollView.delegate != self.delegateProxy)
    {
        self.delegateProxy.originalDelegate = _scrollView.delegate;
        _scrollView.delegate = (id)self.delegateProxy;
    }
    
    [self updateScrollViewInsets];
}

- (CGRect)extensionViewBounds
{
    return self.extensionViewContainer.bounds;
}

- (BOOL)isViewControllerVisible
{
    return self.viewController.isViewLoaded && self.viewController.view.window;
}

- (BOOL)isMidTransition
{
    return (!self.navBarController.expanded && !self.navBarController.contracted) || (!self.extensionController.expanded && !self.extensionController.contracted);
}

- (void)setDisable:(BOOL)disable
{
    if (disable == _disable)
    {
        return;
    }

    _disable = disable;

    if (!disable) {
        self.previousYOffset = self.scrollView.contentOffset.y;
    }
}

- (void)setHasCustomRefreshControl:(BOOL)hasCustomRefreshControl
{
    if (_hasCustomRefreshControl == hasCustomRefreshControl)
    {
        return;
    }
    
    _hasCustomRefreshControl = hasCustomRefreshControl;
    
    self.scrollViewController.hasCustomRefreshControl = hasCustomRefreshControl;
}

- (BOOL)stickyNavigationBar
{
    return self.navBarController.sticky;
}

- (void)setStickyNavigationBar:(BOOL)stickyNavigationBar
{
    self.navBarController.sticky = stickyNavigationBar;
}

- (BOOL)stickyExtensionView
{
    return self.extensionController.sticky;
}

- (void)setStickyExtensionView:(BOOL)stickyExtensionView
{
    self.extensionController.sticky = stickyExtensionView;
}

- (CGFloat)height
{
    return self.extensionController.calculateTotalHeightRecursively;
}

- (CGFloat)bottom
{
    return self.extensionController.calculateBottomRecursively;
}


#pragma mark - Private methods

- (BOOL)_scrollViewIsSuffecientlyLong
{
    CGRect scrollFrame = UIEdgeInsetsInsetRect(self.scrollView.bounds, self.scrollView.contentInset);
    CGFloat scrollableAmount = self.scrollView.contentSize.height - CGRectGetHeight(scrollFrame);
    return (scrollableAmount > [self.extensionController calculateTotalHeightRecursively]);
}

- (BOOL)_shouldHandleScrolling
{
    if (self.disable)
    {
        return NO;
    }

    return (self.isViewControllerVisible && [self _scrollViewIsSuffecientlyLong]);
}

- (void)_handleScrolling
{
    self.scrolling = YES;
    
    if (![self _shouldHandleScrolling])
    {
        return;
    }

    if (!isnan(self.previousYOffset))
    {
        // 1 - Calculate the delta
        CGFloat deltaY = (self.previousYOffset - self.scrollView.contentOffset.y);

        // 2 - Ignore any scrollOffset beyond the bounds
        CGFloat start = -self.scrollView.contentInset.top;
        if (self.previousYOffset < start)
        {
            deltaY = MIN(0, deltaY - (self.previousYOffset - start));
        }

        /* rounding to resolve a dumb issue with the contentOffset value */
        CGFloat end = floorf(self.scrollView.contentSize.height - CGRectGetHeight(self.scrollView.bounds) + self.scrollView.contentInset.bottom - 0.5f);
        if (self.previousYOffset > end && deltaY > 0)
        {
            deltaY = MAX(0, deltaY - self.previousYOffset + end);
        }

        // 3 - Update contracting variable
        if (fabs(deltaY) > FLT_EPSILON)
        {
            self.contracting = deltaY < 0;
        }

        // 4 - Check if contracting state changed, and do stuff if so
        if (self.contracting != self.previousContractionState)
        {
            self.previousContractionState = self.contracting;
            self.resistanceConsumed = 0;
        }

        // GTH: Calculate the exact point to avoid expansion resistance
        // CGFloat statusBarHeight = [self.statusBarController calculateTotalHeightRecursively];

        // 5 - Apply resistance
        // 5.1 - Always apply resistance when contracting
        if (self.contracting)
        {
            CGFloat availableResistance = self.contractionResistance - self.resistanceConsumed;
            self.resistanceConsumed = MIN(self.contractionResistance, self.resistanceConsumed - deltaY);

            deltaY = MIN(0, availableResistance + deltaY);
        }
        // 5.2 - Only apply resistance if expanding above the status bar
        else if (self.scrollView.contentOffset.y > 0)
        {
            CGFloat availableResistance = self.expansionResistance - self.resistanceConsumed;
            self.resistanceConsumed = MIN(self.expansionResistance, self.resistanceConsumed + deltaY);

            deltaY = MAX(0, deltaY - availableResistance);
        }

        // 6 - Update the navigation bar shyViewController
        self.navBarController.fadeBehavior = self.fadeBehavior;
        self.navBarController.scaleBehaviour = self.scaleBehavior;

        // 7 - Inform the delegate if needed
        CGFloat maxNavY = CGRectGetMaxY(self.navBarController.view.frame);
        CGFloat maxExtensionY = CGRectGetMaxY(self.extensionViewContainer.frame);
        CGFloat visibleTop;
        if (self.extensionViewContainer.hidden) {
            visibleTop = maxNavY;
        } else {
            visibleTop = MAX(maxNavY, maxExtensionY);
        }
        if (visibleTop == self.statusBarController.calculateTotalHeightRecursively) {
            if ([self.delegate respondsToSelector:@selector(shyNavBarManagerDidBecomeFullyContracted:)]) {
                [self.delegate shyNavBarManagerDidBecomeFullyContracted:self];
            }
        }

        [self.navBarController updateYOffset:deltaY];
    }
    
    [self updateScrollViewInsets];
}

- (void)_handleScrollingEnded
{
    self.scrolling = NO;
    
    if (!self.isViewControllerVisible)
    {
        return;
    }

    __weak __typeof(self) weakSelf = self;
    void (^completion)() = ^
    {
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            if (strongSelf.contracting) {
                if ([strongSelf.delegate respondsToSelector:@selector(shyNavBarManagerDidFinishContracting:)]) {
                    [strongSelf.delegate shyNavBarManagerDidFinishContracting:strongSelf];
                }
            } else {
                if ([strongSelf.delegate respondsToSelector:@selector(shyNavBarManagerDidFinishExpanding:)]) {
                    [strongSelf.delegate shyNavBarManagerDidFinishExpanding:strongSelf];
                }
            }
        }
    };

    self.resistanceConsumed = 0;
    [self.navBarController snap:self.contracting completion:completion];
}

#pragma mark - public methods

- (void)setExtensionView:(UIView *)view
{
    if (view != _extensionView)
    {
        [_extensionView removeFromSuperview];
        _extensionView = view;
        
        view.frame = view.bounds;

        self.extensionViewContainer.frame = view.bounds;
        [self.extensionViewContainer addSubview:view];
        self.extensionViewContainer.userInteractionEnabled = view.userInteractionEnabled;

        /* Disable scroll handling temporarily while laying out views to avoid double-changing content
         * offsets in _handleScrolling. */
        BOOL wasDisabled = self.disable;
        self.disable = YES;
        self.disable = wasDisabled;
        
        [self.extensionController expand];
    }
}

- (void)cleanup
{
    [self.navBarController expand];
    self.previousYOffset = NAN;
}

- (void)updateScrollViewInsets
{
    if (self.automaticallyAdjustsScrollViewInsets)
    {
        id<UIScrollViewDelegate> delegate = self.scrollView.delegate;
        
        self.scrollView.delegate = nil;
        
        self.scrollView.contentInset = UIEdgeInsetsMake(self.bottom,
                                                        self.scrollView.contentInset.left,
                                                        self.scrollView.contentInset.bottom,
                                                        self.scrollView.contentInset.right);

        self.scrollView.scrollIndicatorInsets = self.scrollView.contentInset;
        
        if ((self.scrollView.contentOffset.y == 0 ||
             self.scrollView.contentOffset.y == -self.navBarController.calculateTotalHeightRecursively ||
             self.scrollView.contentOffset.y == -self.extensionController.calculateTotalHeightRecursively)
            && !self.scrolling)
        {
            self.scrollView.contentOffset = CGPointMake(self.scrollView.contentOffset.x, -self.scrollView.contentInset.top);
        }
        
        self.scrollView.delegate = delegate;
    }
    
    self.previousYOffset = self.scrollView.contentOffset.y;
}

#pragma mark - UIScrollViewDelegate methods

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    [self _handleScrolling];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (!decelerate)
    {
        [self _handleScrollingEnded];
    }
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView
{
    [self.scrollView scrollRectToVisible:CGRectMake(0,0,1,1) animated:YES];
    [self.scrollView flashScrollIndicators];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self _handleScrollingEnded];
}

#pragma mark - TLYShyViewControllerDelegate methods

- (void)shyViewControllerDidExpand:(TLYShyViewController *)shyViewController
{
    [self updateScrollViewInsets];
}

- (void)shyViewControllerDidContract:(TLYShyViewController *)shyViewController
{
    [self updateScrollViewInsets];
}

#pragma mark - NSNotificationCenter methods

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    if (self.scrollView.window) {
        [self.navBarController expand];
    }
}

@end

#pragma mark - UIViewController+TLYShyNavBar category

static char shyNavBarManagerKey;

@implementation UIViewController (ShyNavBar)

#pragma mark - Static methods

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self tly_swizzleInstanceMethod:@selector(viewWillAppear:) withReplacement:@selector(tly_swizzledViewWillAppear:)];
        [self tly_swizzleInstanceMethod:@selector(viewWillDisappear:) withReplacement:@selector(tly_swizzledViewWillDisappear:)];
    });
}

#pragma mark - Swizzled View Life Cycle

- (void)tly_swizzledViewWillAppear:(BOOL)animated
{
    [[self _internalShyNavBarManager] cleanup];
    [self tly_swizzledViewWillAppear:animated];
}

- (void)tly_swizzledViewWillDisappear:(BOOL)animated
{
    [[self _internalShyNavBarManager] cleanup];
    [self tly_swizzledViewWillDisappear:animated];
}

#pragma mark - Public methods

- (BOOL)isShyNavBarManagerPresent
{
    return [self _internalShyNavBarManager] != nil;
}

- (void)setShyNavBarManager:(TLYShyNavBarManager *)shyNavBarManager
             viewController:(UIViewController *)viewController
{
    NSAssert(viewController != nil, @"viewController must not be nil!");
    shyNavBarManager.viewController = viewController;
    objc_setAssociatedObject(self, &shyNavBarManagerKey, shyNavBarManager, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Properties

- (void)setShyNavBarManager:(TLYShyNavBarManager *)shyNavBarManager
{
    [self setShyNavBarManager:shyNavBarManager viewController:self];
}

- (TLYShyNavBarManager *)shyNavBarManager
{
    id shyNavBarManager = objc_getAssociatedObject(self, &shyNavBarManagerKey);
    if (!shyNavBarManager)
    {
        shyNavBarManager = [[TLYShyNavBarManager alloc] init];
        self.shyNavBarManager = shyNavBarManager;
    }

    return shyNavBarManager;
}

#pragma mark - Private methods

/* Internally, we need to access the variable without creating it */
- (TLYShyNavBarManager *)_internalShyNavBarManager
{
    return objc_getAssociatedObject(self, &shyNavBarManagerKey);
}

@end

