#!/usr/bin/env python3
"""Generate native macOS app and Automator metadata; no external dependencies."""
import pathlib
import plistlib
import sys
import uuid

app = pathlib.Path(sys.argv[1])
resources = app / 'Contents/Resources'
resources.mkdir(parents=True, exist_ok=True)

def dump(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(obj, sort_keys=False))

dump(app / 'Contents/Info.plist', {
    'CFBundleName': 'Orbit', 'CFBundleDisplayName': 'Orbit',
    'CFBundleExecutable': 'Orbit', 'CFBundleIdentifier': 'dev.ybivashhka.orbit',
    'CFBundleVersion': '7', 'CFBundleShortVersionString': '1.5',
    'CFBundlePackageType': 'APPL', 'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleIconFile': 'Orbit', 'LSMinimumSystemVersion': '14.0',
    'LSUIElement': True, 'LSMultipleInstancesProhibited': True,
    'NSHighResolutionCapable': True,
    'CFBundleURLTypes': [{'CFBundleURLName': 'dev.ybivashhka.orbit.selection', 'CFBundleURLSchemes': ['orbit-convert'], 'CFBundleTypeRole': 'Viewer'}],
    'NSAppleEventsUsageDescription': 'Orbit использует Word или Pages на вашем Mac, чтобы экспортировать документы без загрузки в интернет.',
    'CFBundleDocumentTypes': [{
        'CFBundleTypeName': 'Документы и изображения', 'CFBundleTypeRole': 'Viewer',
        'LSHandlerRank': 'Alternate',
        'LSItemContentTypes': ['public.image', 'com.adobe.pdf', 'public.text', 'public.rtf',
                              'org.openxmlformats.wordprocessingml.document', 'com.microsoft.word.doc',
                              'org.oasis-open.opendocument.text', 'com.apple.iwork.pages.pages',
                              'public.audio', 'public.movie', 'public.archive', 'public.comma-separated-values-text',
                              'public.tab-separated-values-text', 'org.matroska.subrip', 'org.w3.webvtt'],
    }],
    'NSHumanReadableCopyright': '© 2026 Artur Karimov. MIT License.',
})

workflow = resources / 'Конвертировать с Orbit.workflow/Contents'
dump(workflow / 'Info.plist', {
    'OrbitWorkflow': True,
    'NSServices': [{
        'NSMenuItem': {'default': 'Конвертировать с Orbit'},
        'NSMessage': 'runWorkflowAsService',
        'NSSendFileTypes': ['public.item'],
        'NSSendTypes': ['NSFilenamesPboardType', 'public.file-url'],
        'NSReturnTypes': [],
        'NSIconName': 'NSActionTemplate',
        'NSRequiredContext': {},
    }],
})
action = {
    'ActionBundlePath': '/System/Library/Automator/Run Shell Script.action',
    'ActionName': 'Run Shell Script',
    'ActionParameters': {
        'CheckedForUserDefaultShell': True, 'inputMethod': 1,
        'shell': '/bin/zsh', 'source': '',
        'COMMAND_STRING': '/usr/bin/open -a Orbit -- "$@"',
    },
    'AMAccepts': {'Container': 'List', 'Optional': False, 'Types': ['com.apple.cocoa.path']},
    'AMProvides': {'Container': 'List', 'Types': ['com.apple.cocoa.string']},
    'AMActionVersion': '2.0.3', 'AMApplication': ['Automator'],
    'AMParameterProperties': {k: {} for k in ['CheckedForUserDefaultShell', 'COMMAND_STRING', 'inputMethod', 'shell', 'source']},
    'BundleIdentifier': 'com.apple.RunShellScript', 'CanShowSelectedItemsWhenRun': False,
    'CanShowWhenRun': True, 'Category': ['AMCategoryUtilities'], 'CFBundleVersion': '2.0.3',
    'Class Name': 'RunShellScriptAction', 'InputUUID': str(uuid.uuid4()).upper(),
    'OutputUUID': str(uuid.uuid4()).upper(), 'UUID': str(uuid.uuid4()).upper(),
    'UnlocalizedApplications': ['Automator'], 'isViewVisible': False,
    'nibPath': '/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib',
}
dump(workflow / 'document.wflow', {
    'AMApplicationBuild': '534', 'AMApplicationVersion': '2.10', 'AMDocumentVersion': '2',
    'actions': [{'action': action, 'isViewVisible': False}], 'connectors': {},
    'workflowMetaData': {
        'applicationBundleIDsByPath': {}, 'applicationPaths': [],
        'inputTypeIdentifier': 'com.apple.Automator.fileSystemObject',
        'outputTypeIdentifier': 'com.apple.Automator.nothing',
        'serviceInputTypeIdentifier': 'com.apple.Automator.fileSystemObject',
        'serviceOutputTypeIdentifier': 'com.apple.Automator.nothing',
        'serviceProcessesInput': False, 'processesInput': False,
        'presentationMode': 11, 'useAutomaticInputType': False,
        'systemImageName': 'NSActionTemplate',
        'workflowTypeIdentifier': 'com.apple.Automator.servicesMenu',
    },
})

# Finder Sync contributes a direct menu item, independently of Automator services.
dump(app / 'Contents/PlugIns/OrbitFinder.appex/Contents/Info.plist', {
    'CFBundleName': 'Orbit Finder', 'CFBundleDisplayName': 'Orbit — Конвертировать',
    'CFBundleExecutable': 'OrbitFinder', 'CFBundleIdentifier': 'dev.ybivashhka.orbit.finder',
    'CFBundleVersion': '7', 'CFBundleShortVersionString': '1.5',
    'CFBundlePackageType': 'XPC!', 'CFBundleInfoDictionaryVersion': '6.0',
    'LSMinimumSystemVersion': '14.0',
    'NSExtension': {
        'NSExtensionAttributes': {},
        'NSExtensionPointIdentifier': 'com.apple.FinderSync',
        'NSExtensionPrincipalClass': 'OrbitFinderSync',
    },
})
