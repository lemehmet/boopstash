# App icon

`Boopstash-Icon-1024.png` is the 1024×1024 master. The macOS sizes in
`App/Resources/Assets.xcassets/AppIcon.appiconset` are made from it.

The master is opaque, and on purpose. macOS 26 clips an opaque full-square
icon to its own app-icon shape. An icon with transparent corners is treated
as a different shape and placed inside a light container instead.
