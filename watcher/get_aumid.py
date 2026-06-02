"""Extract AUMID from MSIX AppxManifest.xml"""
import xml.etree.ElementTree as ET

manifest_path = r'C:\Program Files\WindowsApps\Claude_1.6608.2.0_x64__pzs8sxrjxfjjc\AppxManifest.xml'
tree = ET.parse(manifest_path)
root = tree.getroot()

# Define namespaces
ns = {
    'm': 'http://schemas.microsoft.com/appx/manifest/foundation/windows10',
    'uap': 'http://schemas.microsoft.com/appx/manifest/uap/windows10',
    'uap5': 'http://schemas.microsoft.com/appx/manifest/uap/windows10/5',
    'uap10': 'http://schemas.microsoft.com/appx/manifest/uap/windows10/10',
}

# Get package identity
identity = root.find('m:Identity', ns)
if identity is not None:
    print(f"PackageName: {identity.get('Name')}")
    print(f"Publisher: {identity.get('Publisher')}")
    print(f"Version: {identity.get('Version')}")

# Get applications
for app in root.findall('.//m:Application', ns):
    app_id = app.get('Id')
    print(f"AppId: {app_id}")

    # Check for execution alias
    for ext in app.findall('.//uap5:Extension', ns):
        if ext.get('Category') == 'windows.appExecutionAlias':
            for alias in ext.findall('.//uap5:ExecutionAlias', ns):
                print(f"Alias: {alias.get('Alias')}")

# The AUMID is: PackageFamilyName!AppId
# PackageFamilyName = PackageName_PublisherId
identity = root.find('m:Identity', ns)
if identity is not None:
    pkg_name = identity.get('Name')
    publisher = identity.get('Publisher')
    # Extract publisher ID from the Publisher attribute
    # Publisher format: CN=... or similar
    # The PackageFamilyName includes a hashed publisher ID
    # Let's look for it in the manifest
    print(f"\nAUMID format: {pkg_name}!AppId")

# Also find the PackageFamilyName if present
for prop in root.findall('.//m:Properties', ns):
    fn = prop.find('m:DisplayName', ns)
    if fn is not None:
        print(f"DisplayName: {fn.text}")
