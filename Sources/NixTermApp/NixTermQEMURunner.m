// Adapted from UTMProcess and UTMQemuSystem.
// Copyright 2019-2026 osy and UTM contributors.
// Licensed under the Apache License, Version 2.0.

#import "NixTermQEMURunner.h"

#import <dlfcn.h>
#import <pthread.h>

typedef int (*QEMUInit)(int argc, const char *argv[], const char *envp[]);
typedef void (*QEMUMainLoop)(void);
typedef void (*QEMUCleanup)(void);

@interface NixTermQEMURunner ()

@property(nonatomic) NSArray<NSString *> *arguments;

@end


@implementation NixTermQEMURunner {
    void *_handle;
    pthread_t _thread;
    QEMUInit _qemuInit;
    QEMUMainLoop _qemuMainLoop;
    QEMUCleanup _qemuCleanup;
}

static void *runQEMU(void *context) {
    NixTermQEMURunner *runner = (__bridge_transfer NixTermQEMURunner *)context;
    NSArray<NSString *> *arguments = runner.arguments;
    int argc = (int)arguments.count + 1;
    char **argv = calloc((size_t)argc + 1, sizeof(char *));
    argv[0] = strdup("qemu-aarch64-softmmu");
    for (NSUInteger index = 0; index < arguments.count; index++) {
        argv[index + 1] = strdup(arguments[index].UTF8String);
    }

    const char *environment[] = { NULL };
    int status = runner->_qemuInit(argc, (const char **)argv, environment);
    if (status == 0) {
        runner->_qemuMainLoop();
        runner->_qemuCleanup();
    }

    for (int index = 0; index < argc; index++) {
        free(argv[index]);
    }
    free(argv);
    return NULL;
}

- (void)startWithArguments:(NSArray<NSString *> *)arguments
                completion:(void (^)(NSError *_Nullable error))completion {
    NSURL *frameworks = NSBundle.mainBundle.privateFrameworksURL;
    NSURL *library = [[frameworks URLByAppendingPathComponent:@"qemu-aarch64-softmmu.framework"]
        URLByAppendingPathComponent:@"qemu-aarch64-softmmu"];
    _handle = dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!_handle) {
        NSString *message = [NSString stringWithUTF8String:dlerror() ?: "Unable to load QEMU"];
        completion([NSError errorWithDomain:@"dev.nixterm.qemu"
                                       code:1
                                   userInfo:@{NSLocalizedDescriptionKey : message}]);
        return;
    }

    _qemuInit = dlsym(_handle, "qemu_init");
    _qemuMainLoop = dlsym(_handle, "qemu_main_loop");
    _qemuCleanup = dlsym(_handle, "qemu_cleanup");
    if (!_qemuInit || !_qemuMainLoop || !_qemuCleanup) {
        completion([NSError errorWithDomain:@"dev.nixterm.qemu"
                                       code:2
                                   userInfo:@{NSLocalizedDescriptionKey : @"QEMU entry points are missing"}]);
        return;
    }

    self.arguments = arguments;
    setenv("TMPDIR", NSFileManager.defaultManager.temporaryDirectory.fileSystemRepresentation, 1);

    __weak NixTermQEMURunner *weakRunner = self;
    if (atexit_b(^{
        NixTermQEMURunner *runner = weakRunner;
        if (runner && pthread_equal(pthread_self(), runner->_thread)) {
            pthread_exit(NULL);
        }
    }) != 0) {
        completion([NSError errorWithDomain:@"dev.nixterm.qemu"
                                       code:3
                                   userInfo:@{NSLocalizedDescriptionKey : @"Unable to install QEMU exit handler"}]);
        return;
    }

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0);
    int result = pthread_create(&_thread, &attributes, runQEMU, (__bridge_retained void *)self);
    pthread_attr_destroy(&attributes);
    if (result != 0) {
        completion([NSError errorWithDomain:@"dev.nixterm.qemu"
                                       code:4
                                   userInfo:@{NSLocalizedDescriptionKey : @"Unable to start QEMU thread"}]);
        return;
    }
    completion(nil);
}

@end
