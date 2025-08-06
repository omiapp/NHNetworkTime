#import <arpa/inet.h>

#import "NHNetworkClock.h"
#import "NHNTLog.h"

#define kTimeOffsetKey @"kTimeOffsetKey"

@interface NHNetworkClock () <NHNetAssociationDelegate>

@property (atomic, copy) NSArray *timeAssociations;
@property NSArray *sortDescriptors;
@property NSSortDescriptor *dispersionSortDescriptor;
@property dispatch_queue_t associationDelegateQueue;
@property (readwrite) BOOL isSynchronized;

@end

@implementation NHNetworkClock

+ (instancetype)sharedNetworkClock {
    static id sharedNetworkClockInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sharedNetworkClockInstance = [[self alloc] init];
    });

    return sharedNetworkClockInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        self.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"dispersion" ascending:YES]];
        self.timeAssociations = [NSArray array];
        self.shouldUseSavedSynchronizedTime = YES;
        self.isAutoSynchronizedWhenUserChangeLocalTime = YES;
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationSignificantTimeChangeNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
            if(self.isAutoSynchronizedWhenUserChangeLocalTime) {
                [self synchronize];
            }
        }];
    }
    
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reset {
    self.isSynchronized = NO;
    [self finishAssociations];
    self.timeAssociations = [NSArray array];
}

// Return the offset to network-derived UTC.

- (NSTimeInterval)networkOffset {
    // 1. 过滤出所有 active 的 NHNetAssociation 对象 (O(N))
    NSMutableArray *mutableAssciation = self.timeAssociations.mutableCopy;
    NSPredicate *filterPredicate = [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        return [evaluatedObject isKindOfClass:[NHNetAssociation class]] && ((NHNetAssociation *)evaluatedObject).active;
    }];
    NSArray<NHNetAssociation *> *activeAssociations = [mutableAssciation filteredArrayUsingPredicate:filterPredicate];

    // 2. 将 active 的对象分为 trusty 和 non-trusty 两组 (O(N))
    NSMutableArray<NHNetAssociation *> *trustyAssociations = [NSMutableArray array];
    NSMutableArray<NHNetAssociation *> *associationsToRemove = [NSMutableArray array];

    for (NHNetAssociation *association in activeAssociations) {
        if (association.trusty) {
            [trustyAssociations addObject:association];
        } else {
            // 如果 non-trusty 且总数超过8，则标记为待删除
            if (self.timeAssociations.count > 8) {
                [associationsToRemove addObject:association];
            }
        }
    }

    // 3. 对 non-trusty 对象进行清理（在所有计算完成后）
    if (associationsToRemove.count > 0) {
        [mutableAssciation removeObjectsInArray:associationsToRemove];
        for (NHNetAssociation *association in associationsToRemove) {
            [association finish];
        }
        self.timeAssociations = mutableAssciation;
    }

    // 4. 对 trusty 对象进行计算
    NSTimeInterval totalOffset = 0.0;
    NSUInteger usefulCount = 0;

    if (trustyAssociations.count > 0) {
        // 5. 只对 trusty 对象进行排序 (O(k log k)，k 是 trusty 对象的数量)
        [trustyAssociations sortUsingDescriptors:self.sortDescriptors];

        // 6. 计算前8个最佳结果的平均值
        for (NHNetAssociation *association in trustyAssociations) {
            totalOffset += association.offset;
            usefulCount++;
            if (usefulCount == 8) {
                break;
            }
        }
    }
    
    if (usefulCount > 0) {
        return totalOffset / usefulCount;
    }

    // 7. 如果没有任何 trusty 的结果，则使用备用方案
    if (self.shouldUseSavedSynchronizedTime) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:kTimeOffsetKey];
    }

    return 0.0;
}

#pragma mark - Get time

- (NSDate *)networkTime {
    return [[NSDate date] dateByAddingTimeInterval:-[self networkOffset]];
}

#pragma mark - Associations

// Use the following time servers or, if it exists, read the "ntp.hosts" file from the application resources and derive all the IP addresses referred to, remove any duplicates and create an 'association' (individual host client) for each one.

- (void)createAssociations {
	@synchronized(self) {
		NSArray *ntpDomains;
		NSString *filePath = [[NSBundle mainBundle] pathForResource:@"ntp.hosts" ofType:@""];
		if (nil == filePath) {
			ntpDomains = @[@"0.pool.ntp.org",
						   @"0.uk.pool.ntp.org",
						   @"0.us.pool.ntp.org",
						   @"asia.pool.ntp.org",
						   @"europe.pool.ntp.org",
						   @"north-america.pool.ntp.org",
						   @"south-america.pool.ntp.org",
						   @"oceania.pool.ntp.org",
						   @"africa.pool.ntp.org"];
		}
		else {
			NSString *fileData = [[NSString alloc] initWithData:[[NSFileManager defaultManager]
																	   contentsAtPath:filePath]
															 encoding:NSUTF8StringEncoding];

			ntpDomains = [fileData componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
		}

		// for each NTP service domain name in the 'ntp.hosts' file : "0.pool.ntp.org" etc ...
		NSMutableSet *hostAddresses = [NSMutableSet setWithCapacity:100];

		for (NSString *ntpDomainName in ntpDomains) {
			if ([ntpDomainName length] == 0 ||
				[ntpDomainName characterAtIndex:0] == ' ' ||
				[ntpDomainName characterAtIndex:0] == '#') {
				continue;
			}

			// ... resolve the IP address of the named host : "0.pool.ntp.org" --> [123.45.67.89], ...
			CFHostRef ntpHostName = CFHostCreateWithName (nil, (__bridge CFStringRef)ntpDomainName);
			if (nil == ntpHostName) {
				NTP_Logging(@"CFHostCreateWithName <nil> for %@", ntpDomainName);
				continue;                                           // couldn't create 'host object' ...
			}

			CFStreamError   nameError;
			if (!CFHostStartInfoResolution (ntpHostName, kCFHostAddresses, &nameError)) {
				NTP_Logging(@"CFHostStartInfoResolution error %i for %@", (int)nameError.error, ntpDomainName);
				CFRelease(ntpHostName);
				continue;                                           // couldn't start resolution ...
			}

			Boolean nameFound;
			CFArrayRef ntpHostAddrs = CFHostGetAddressing (ntpHostName, &nameFound);

			if (!nameFound) {
				NTP_Logging(@"CFHostGetAddressing: %@ NOT resolved", ntpHostName);
				CFRelease(ntpHostName);
				continue;                                           // resolution failed ...
			}

			if (ntpHostAddrs == nil) {
				NTP_Logging(@"CFHostGetAddressing: no addresses resolved for %@", ntpHostName);
				CFRelease(ntpHostName);
				continue;                                           // NO addresses were resolved ...
			}
			//for each (sockaddr structure wrapped by a CFDataRef/NSData *) associated with the hostname, drop the IP address string into a Set to remove duplicates.
			for (NSData *ntpHost in (__bridge NSArray *)ntpHostAddrs) {
				[hostAddresses addObject:[GCDAsyncUdpSocket hostFromAddress:ntpHost]];
			}

			CFRelease(ntpHostName);
		}

		NTP_Logging(@"%@", hostAddresses);                          // all the addresses resolved

		// ... now start one 'association' (network clock server) for each address.
        NSMutableArray *mutableAssociations = [NSMutableArray arrayWithCapacity:100];
		for (NSString *server in hostAddresses) {
			NHNetAssociation *    timeAssociation = [[NHNetAssociation alloc] initWithServerName:server];
			timeAssociation.delegate = self;

			[mutableAssociations addObject:timeAssociation];
			[timeAssociation enable];                               // starts are randomized internally
		}
        self.timeAssociations = mutableAssociations;
	}
}

// Stop all the individual ntp clients associations ..

- (void)finishAssociations {
    NSArray *timeAssociationsCopied = self.timeAssociations;
    for (NHNetAssociation * timeAssociation in timeAssociationsCopied) {
        timeAssociation.delegate = nil;
        [timeAssociation finish];
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Sync

- (void)synchronize {
    [self reset];
    
    [[[NSOperationQueue alloc] init] addOperation:[[NSInvocationOperation alloc]
                                                   initWithTarget:self
                                                   selector:@selector(createAssociations)
                                                   object:nil]];
}

#pragma mark - NHNetAssociationDelegate

- (void)netAssociationDidFinishGetTime:(NHNetAssociation *)netAssociation {
    if(netAssociation.active && netAssociation.trusty) {
        
        [[NSUserDefaults standardUserDefaults] setDouble:netAssociation.offset forKey:kTimeOffsetKey];
        
        if (self.isSynchronized == NO) {
            [[NSNotificationCenter defaultCenter] postNotificationName:kNHNetworkTimeSyncCompleteNotification object:nil userInfo:nil];
            self.isSynchronized = YES;
        }
    }
}

@end
