//
//  MessagesViewController.m
//  MessagesExtension
//
//  Created by Wildog on 9/18/16.
//  Copyright © 2016 Wildog. All rights reserved.
//

#import "StepsMessagesViewController.h"
//#import <HealthKit/HealthKit.h>
#import <CoreMotion/CoreMotion.h>
#import "WDLineChartView.h"

@interface StepsMessagesViewController () <WDLineChartViewDataSource, WDLineChartViewDelegate> {
    NSArray *_elementValues;
    NSArray *_elementLables;
    NSArray *_elementDistances;
    NSArray *_elementFlights;
    NSUInteger _numberCount;
    NSUInteger _lastSelected;
    NSInteger _currentMax;
    NSDateFormatter *_formatter;
    NSString *_unit;
    NSUserDefaults *_shared;
    BOOL _errorOccurred;
}

@property (weak, nonatomic) IBOutlet WDLineChartView *lineChartView;
@property (weak, nonatomic) IBOutlet UILabel *label;
@property (weak, nonatomic) IBOutlet UIButton *sendButton;
//@property (nonatomic, strong) HKHealthStore *healthStore;
@property (nonatomic, strong) CMPedometer *pedometer;

@end

@implementation StepsMessagesViewController

#pragma mark - Conversation Handling

- (IBAction)sendButtonDidPress:(id)sender {
    //generate image
    //CGFloat xPos = _lineChartView.frame.origin.x + 10;
    //CGFloat yPos = _lineChartView.frame.origin.y;
    UIGraphicsBeginImageContextWithOptions(_lineChartView.bounds.size, NO, 0);
    //CGContextRef context = UIGraphicsGetCurrentContext();
    //CGContextTranslateCTM(context, -xPos, -yPos);
    //[self.view.layer.presentationLayer renderInContext:context];
    [_lineChartView drawViewHierarchyInRect:_lineChartView.bounds afterScreenUpdates:NO];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    //create msg
    MSMessageTemplateLayout *layout = [[MSMessageTemplateLayout alloc] init];
    layout.image = img;
    NSString *dateString = [@"on " stringByAppendingString:[self labelForElementAtIndex:_lastSelected]];
    if (_lastSelected == _numberCount - 1) {
        dateString = @"today";
    } else if (_lastSelected == _numberCount - 2) {
        dateString = @"yesterday";
    }
    layout.caption = [NSString stringWithFormat:@"I moved %.0f steps, %.2f %@ %@.",
                      [self valueForElementAtIndex:_lastSelected],
                      [(NSNumber*)_elementDistances[_lastSelected] doubleValue],
                      _unit,
                      dateString];
    MSMessage *msg = [[MSMessage alloc] init];
    msg.layout = layout;
    msg.URL = [NSURL URLWithString:@"emptyURL"];
    
    //send to active conversation
    [self.activeConversation insertMessage:msg completionHandler:^(NSError *error){
        if (error != nil) {
            _label.text = @"failed to create msg";
        }
    }];
    
    //dismiss extension
    [self dismiss];
}

-(void)didBecomeActiveWithConversation:(MSConversation *)conversation {
    // Called when the extension is about to move from the inactive to active state.
    // This will happen when the extension is about to present UI.
    
    // Use this method to configure the extension and restore previously stored state.
}

-(void)willResignActiveWithConversation:(MSConversation *)conversation {
    // Called when the extension is about to move from the active to inactive state.
    // This will happen when the user dissmises the extension, changes to a different
    // conversation or quits Messages.
    
    // Use this method to release shared resources, save user data, invalidate timers,
    // and store enough state information to restore your extension to its current state
    // in case it is terminated later.
}

-(void)didReceiveMessage:(MSMessage *)message conversation:(MSConversation *)conversation {
    // Called when a message arrives that was generated by another instance of this
    // extension on a remote device.
    
    // Use this method to trigger UI updates in response to the message.
}

-(void)didStartSendingMessage:(MSMessage *)message conversation:(MSConversation *)conversation {
    // Called when the user taps the send button.
}

-(void)didCancelSendingMessage:(MSMessage *)message conversation:(MSConversation *)conversation {
    // Called when the user deletes the message without sending it.
    
    // Use this to clean up state related to the deleted message.
}

-(void)willTransitionToPresentationStyle:(MSMessagesAppPresentationStyle)presentationStyle {
    // Called before the extension transitions to a new presentation style.
    
    // Use this method to prepare for the change in presentation style.
}

-(void)didTransitionToPresentationStyle:(MSMessagesAppPresentationStyle)presentationStyle {
    // Called after the extension transitions to a new presentation style.
    
    // Use this method to finalize any behaviors associated with the change in presentation style.
}

#pragma mark vc methods

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        _errorOccurred = NO;
        _numberCount = 7;
        _lastSelected = _numberCount - 1;
        _currentMax = 0;
        _formatter = [[NSDateFormatter alloc] init];
        [_formatter setDateFormat:@"M/d"];
        //_healthStore = [[HKHealthStore alloc] init];
        _pedometer = [[CMPedometer alloc] init];
        _shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.wil.dog.iSteps"];
        
        NSString *unit = [_shared stringForKey:@"unit"];
        if (unit != nil) {
            _unit = unit;
        } else {
            _unit = @"km";
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [_lineChartView setDataSource:self];
    [_lineChartView setDelegate:self];
    [_lineChartView setShowAverageLine:NO];
    [_lineChartView setBackgroundLineColor:[UIColor clearColor]];
    [self readHealthKitData];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loadAfterFirstTime) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)loadAfterFirstTime {
    [_lineChartView setAnimated:NO];
    [self readHealthKitData];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

#pragma mark - HealthKit methods
- (void)queryHealthData
{
    NSMutableArray *arrayForValues = [NSMutableArray arrayWithCapacity:_numberCount];
    NSMutableArray *arrayForLabels = [NSMutableArray arrayWithCapacity:_numberCount];
    NSMutableArray *arrayForDistances = [NSMutableArray arrayWithCapacity:_numberCount];
    NSMutableArray *arrayForFlights = [NSMutableArray arrayWithCapacity:_numberCount];
    for (NSUInteger i = 0; i < _numberCount; i++) {
        [arrayForValues addObject:@(0)];
        [arrayForLabels addObject:@""];
        [arrayForDistances addObject:@(0)];
        [arrayForFlights addObject:@(0)];
    }
    _elementValues = (NSArray*)arrayForValues;
    
    dispatch_group_t hkGroup = dispatch_group_create();
    
    //HKQuantityType *stepType =[HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    //HKQuantityType *distanceType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    //HKQuantityType *flightsType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];
    
    NSDate *day = [NSDate date];
    NSCalendar *calendar = [NSCalendar autoupdatingCurrentCalendar];
    
    for (NSUInteger i = 0; i < _numberCount; i++) {
        arrayForLabels[_numberCount - 1 - i] = [_formatter stringFromDate:day];
        
        NSDateComponents *components = [calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:day];
        components.hour = components.minute = components.second = 0;
        NSDate *beginDate = [calendar dateFromComponents:components];
        NSDate *endDate = day;
        if (i != 0) {
            components.hour = 24;
            components.minute = components.second = 0;
            endDate = [calendar dateFromComponents:components];
        }
        // switch from HealthKit to CoreMotion due to its realtime updates and fast data retrieval
        dispatch_group_enter(hkGroup);
        [self.pedometer queryPedometerDataFromDate:beginDate toDate:endDate withHandler:^(CMPedometerData * _Nullable pedometerData, NSError * _Nullable error) {
            if (error != nil) _errorOccurred = YES;
            arrayForValues[_numberCount - 1 - i] = pedometerData.numberOfSteps ? pedometerData.numberOfSteps : @(0);
            arrayForFlights[_numberCount - 1 - i] = pedometerData.floorsAscended ? pedometerData.floorsAscended : @(0);
            if ([_unit isEqualToString:@"km"]) {
                arrayForDistances[_numberCount - 1 - i] = @(pedometerData.distance.doubleValue / 1000.0);
            } else {
                arrayForDistances[_numberCount - 1 - i] = @(pedometerData.distance.doubleValue * 0.000621371);
            }
            if (pedometerData.numberOfSteps.integerValue > _currentMax) {
                _currentMax = pedometerData.numberOfSteps.integerValue;
            }
            dispatch_group_leave(hkGroup);
        }];
        //NSPredicate *predicate = [HKQuery predicateForSamplesWithStartDate:beginDate endDate:endDate options:HKQueryOptionStrictStartDate];
        //
        //HKStatisticsQuery *squery = [[HKStatisticsQuery alloc]
        //                             initWithQuantityType:stepType
        //                             quantitySamplePredicate:predicate
        //                             options:HKStatisticsOptionCumulativeSum
        //                             completionHandler:^(HKStatisticsQuery *query, HKStatistics *result, NSError *error) {
        //        if (error != nil) _errorOccurred = YES;
        //        HKQuantity *quantity = result.sumQuantity;
        //        double step = [quantity doubleValueForUnit:[HKUnit countUnit]];
        //        [arrayForValues setObject:[NSNumber numberWithDouble:step] atIndexedSubscript:_numberCount - 1 - i];
        //        if (step > _currentMax) _currentMax = step;
        //        dispatch_group_leave(hkGroup);
        //}];
        //HKStatisticsQuery *fquery = [[HKStatisticsQuery alloc]
        //                             initWithQuantityType:flightsType
        //                             quantitySamplePredicate:predicate
        //                             options:HKStatisticsOptionCumulativeSum
        //                             completionHandler:^(HKStatisticsQuery *query, HKStatistics *result, NSError *error) {
        //        if (error != nil) _errorOccurred = YES;
        //        HKQuantity *quantity = result.sumQuantity;
        //        double flight = [quantity doubleValueForUnit:[HKUnit countUnit]];
        //        [arrayForFlights setObject:[NSNumber numberWithDouble:flight] atIndexedSubscript:_numberCount - 1 - i];
        //        dispatch_group_leave(hkGroup);
        //}];
        //HKStatisticsQuery *dquery = [[HKStatisticsQuery alloc]
        //                             initWithQuantityType:distanceType
        //                             quantitySamplePredicate:predicate
        //                             options:HKStatisticsOptionCumulativeSum
        //                             completionHandler:^(HKStatisticsQuery *query, HKStatistics *result, NSError *error) {
        //        if (error != nil) _errorOccurred = YES;
        //        HKQuantity *quantity = result.sumQuantity;
        //        double distance = [quantity doubleValueForUnit:[HKUnit unitFromString:_unit]];
        //        [arrayForDistances setObject:[NSNumber numberWithDouble:distance] atIndexedSubscript:_numberCount - 1 - i];
        //        dispatch_group_leave(hkGroup);
        //}];
        //dispatch_group_enter(hkGroup);
        //[_healthStore executeQuery:squery];
        //dispatch_group_enter(hkGroup);
        //[_healthStore executeQuery:fquery];
        //dispatch_group_enter(hkGroup);
        //[_healthStore executeQuery:dquery];
        
        day = [day dateByAddingTimeInterval: -3600 * 24];
    }
    dispatch_group_notify(hkGroup, dispatch_get_main_queue(),^{
        if (!_errorOccurred && _currentMax > 0) {
            _elementValues = (NSArray*)arrayForValues;
            _elementDistances = (NSArray*)arrayForDistances;
            _elementFlights = (NSArray*)arrayForFlights;
            _elementLables = (NSArray*)arrayForLabels;
            [_lineChartView loadDataWithSelectedKept];
            [self changeTextWithNodeAtIndex:_lastSelected];
        } else if (!_errorOccurred && _currentMax <= 0) {
            _label.text = @"No data";
        } else {
            _label.text = @"Motion data not accessible";
        }
    });
}

- (void)readHealthKitData
{
    //if ([HKHealthStore isHealthDataAvailable]) {
    //    HKQuantityType *stepType =[HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    //    HKQuantityType *distanceType = [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    //    HKQuantityType *flightsType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];
    //    [_healthStore requestAuthorizationToShareTypes:nil readTypes:[NSSet setWithObjects:stepType, distanceType, flightsType, nil] completion:^(BOOL success, NSError *error) {
    //        if (success) {
    //            [self queryHealthData];
    //        } else {
    //            _label.text = @"Health Data Permission Denied";
    //        }
    //    }];
    //} else {
    //    _label.text = @"Health Data Not Available";
    //}
    if (![CMPedometer isStepCountingAvailable] || ![CMPedometer isFloorCountingAvailable] || ![CMPedometer isDistanceAvailable]) {
        _label.text = @"Motion Data Not Available";
        return;
    }
    [self queryHealthData];
}

#pragma mark - LineChartViewDataSource methods

- (NSUInteger)numberOfElements {
    return _numberCount;
}

- (CGFloat)maxValue {
    return [[_elementValues valueForKeyPath:@"@max.self"] doubleValue];
}

- (CGFloat)minValue {
    return [[_elementValues valueForKeyPath:@"@min.self"] doubleValue];
}

- (CGFloat)averageValue {
    return [[_elementValues valueForKeyPath:@"@avg.self"] doubleValue];
}

- (CGFloat)valueForElementAtIndex:(NSUInteger)index {
    return [(NSNumber*)_elementValues[index] floatValue];
}

- (NSString*)labelForElementAtIndex:(NSUInteger)index {
    return (NSString*)_elementLables[index];
}

#pragma mark - LineChartViewDelegate methods

- (void)clickedNodeAtIndex:(NSUInteger)index {
    [self changeTextWithNodeAtIndex:index];
    _lastSelected = index;
}

- (void)changeTextWithNodeAtIndex:(NSUInteger)index {
    NSString *result = [NSString stringWithFormat:@"\uF3BB  %.0f\n\n\uE801  %.2f %@\n\n\uF148  %.0f F", [(NSNumber*)_elementValues[index] floatValue], [(NSNumber*)_elementDistances[index] floatValue], _unit, [(NSNumber*)_elementFlights[index] floatValue]];
    _label.text = result;
}

@end
