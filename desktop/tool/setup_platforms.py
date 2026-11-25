#!/usr/bin/env python3
"""Patch the Android folder that `flutter create` generates.

Run from desktop/ (CI does this automatically):

    flutter create --project-name classic_desk --org com.hatdagger --platforms android .
    python3 tool/setup_platforms.py

Adds the native code (AIM keep-alive service, desktop bridge, switch widget),
makes the app a home screen, and signs it with the key in android_overlay so
every build installs over the last one. Safe to run more than once.
"""
import glob
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVERLAY = os.path.join(ROOT, 'android_overlay')
LABEL = 'ClassicDesk'


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def write(p, s):
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)


def patch_android():
    acts = glob.glob(os.path.join(ROOT, 'android', 'app', 'src', 'main', 'kotlin', '**', 'MainActivity.kt'), recursive=True)
    if not acts:
        sys.exit('MainActivity.kt not found - run flutter create first')
    act = acts[0]
    m = re.search(r'^package\s+([\w.]+)', read(act), re.M)
    pkg = m.group(1)
    folder = os.path.dirname(act)
    for name in ('MainActivity.kt', 'AimConnectionService.kt', 'DeskBridge.kt', 'SwitchWidget.kt'):
        write(os.path.join(folder, name), read(os.path.join(OVERLAY, name)).replace('__PACKAGE__', pkg))

    res_src = os.path.join(OVERLAY, 'res')
    res_dst = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    for dirpath, _, files in os.walk(res_src):
        rel = os.path.relpath(dirpath, res_src)
        os.makedirs(os.path.join(res_dst, rel), exist_ok=True)
        for f in files:
            shutil.copy(os.path.join(dirpath, f), os.path.join(res_dst, rel, f))

    man_p = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'AndroidManifest.xml')
    man = read(man_p)
    perms = [
        'android.permission.INTERNET',
        'android.permission.ACCESS_NETWORK_STATE',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
        'android.permission.WAKE_LOCK',
        'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
        'android.permission.VIBRATE',
    ]
    add = ''.join(f'    <uses-permission android:name="{p}"/>\n' for p in perms if p not in man)
    if add:
        man = man.replace('<application', add + '    <application', 1)
    man = re.sub(r'android:label="[^"]*"', f'android:label="{LABEL}"', man, count=1)
    man = man.replace('android:launchMode="singleTop"', 'android:launchMode="singleTask"')

    # Home screen: the launcher intent filter also answers the Home button.
    if 'android.intent.category.HOME' not in man:
        man = man.replace(
            '<category android:name="android.intent.category.LAUNCHER"/>',
            '<category android:name="android.intent.category.LAUNCHER"/>\n'
            '                <category android:name="android.intent.category.HOME"/>\n'
            '                <category android:name="android.intent.category.DEFAULT"/>', 1)
        if 'android.intent.category.HOME' not in man:
            sys.exit('could not add the HOME category to the manifest')

    # See installed apps (Start menu > All Programs).
    if 'android.intent.category.LAUNCHER"/></intent></queries>' not in man:
        q = ('    <queries><intent><action android:name="android.intent.action.MAIN"/>'
             '<category android:name="android.intent.category.LAUNCHER"/></intent></queries>\n')
        man = man.replace('</manifest>', q + '</manifest>', 1)

    if 'AimConnectionService' not in man:
        service = (
            f'        <service android:name="{pkg}.AimConnectionService"\n'
            '            android:exported="false"\n'
            '            android:foregroundServiceType="specialUse">\n'
            '            <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"\n'
            '                android:value="Keeps an instant messaging connection signed on"/>\n'
            '        </service>\n'
            f'        <receiver android:name="{pkg}.SwitchWidget"\n'
            '            android:exported="true"\n'
            '            android:label="Switch to Desktop">\n'
            '            <intent-filter>\n'
            '                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>\n'
            '            </intent-filter>\n'
            '            <meta-data android:name="android.appwidget.provider"\n'
            '                android:resource="@xml/desk_switch_widget_info"/>\n'
            '        </receiver>\n'
        )
        man = man.replace('    </application>', service + '    </application>', 1)
    write(man_p, man)
    patch_signing()
    print('android: patched', pkg)


def patch_signing():
    ks = os.path.join(OVERLAY, 'desk.jks').replace('\\', '/')
    kts = os.path.join(ROOT, 'android', 'app', 'build.gradle.kts')
    if not os.path.exists(kts):
        sys.exit('android/app/build.gradle.kts not found')
    s = read(kts)
    block = (
        '    signingConfigs {\n'
        '        create("desk") {\n'
        f'            storeFile = file("{ks}")\n'
        '            storePassword = "classicdesk"\n'
        '            keyAlias = "desk"\n'
        '            keyPassword = "classicdesk"\n'
        '        }\n'
        '    }\n'
    )
    use = 'signingConfig = signingConfigs.getByName("desk")'
    s = re.sub(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)', use, s)
    if 'create("desk")' not in s:
        s = s.replace('    buildTypes {', block + '    buildTypes {', 1)
    if use not in s:
        sys.exit('could not set the signing key')
    write(kts, s)


if __name__ == '__main__':
    patch_android()
