// Same forwarder as ios/Classes/ne_api.mm, and duplicated for the same reason
// it exists at all: a podspec cannot name sources outside its own directory,
// and CocoaPods will not let one pod declare two platforms whose frameworks
// differ. The two files are one line each; sharing them would cost a symlink
// that does not survive a Windows checkout.
#include "../../src/api.cpp"
