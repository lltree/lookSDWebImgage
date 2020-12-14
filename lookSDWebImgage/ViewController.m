//
//  ViewController.m
//  lookSDWebImgage
//
//  Created by lltree on 2020/12/10.
//

#import "ViewController.h"
#import "UIImageView+WebCache.h"

@interface ViewController ()

@property (weak, nonatomic) IBOutlet UIImageView *firstImgView;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.firstImgView.backgroundColor = UIColor.purpleColor;
    // Do any additional setup after loading the view.
    
    [self.firstImgView sd_setImageWithURL:@"https://pic2.58cdn.com.cn/anjuke_58/beb000b2a31248d34bca0d0b0e3edc08?w=344&h=258&crop=1&w=240&h=180&crop=1&t=1&srotate=1"];
}


@end
