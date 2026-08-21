# Rules for the wireless-ADB provisioning stack.
#
# Conscrypt, BouncyCastle and libadb-android all resolve pieces of themselves
# by name at runtime — security providers are registered reflectively — so
# shrinking them by reachability removes classes that are, in fact, reached.

# Conscrypt carries adapters for platform TLS classes that only existed on
# KitKat and earlier. They are unreachable here and their absence is not a
# problem; R8 just needs telling so.
-dontwarn com.android.org.conscrypt.**
-dontwarn org.apache.harmony.xnet.provider.jsse.**
-keep class org.conscrypt.** { *; }

# The provider is looked up by name, and the certificate builders are
# instantiated through JCA rather than directly.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# The ADB connection manager is subclassed in MmdAdbManager and its protocol
# classes are constructed from parsed wire data.
-keep class io.github.muntashirakon.adb.** { *; }
-dontwarn io.github.muntashirakon.adb.**
