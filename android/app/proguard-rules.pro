# JCIFS-NG rules
-keep class jcifs.** { *; }
-dontwarn jcifs.**

# SLF4J rules
-dontwarn org.slf4j.**

# BouncyCastle rules (prevent algorithms like MD4 from being stripped by R8)
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

