# krakatau-patcher

CLI utility to diff/patch a JAR file using unified diffs and [Krakatau](https://github.com/Storyyeller/Krakatau) in a KISS Bash script.

The intermediary patch file uses [Krakatau assembly](https://github.com/Storyyeller/Krakatau/blob/v2/docs/assembly_specification.md) to be human-readable.

NOTE: Currently, this does not support patching binary files inside the JAR.

## Usage

```
krakatau-patcher diff [original-file] [edited-directory] > bundle.patch
krakatau-patcher patch [original-file] bundle.patch > [output-file]

Options:
  [original-file]:
    Original ".jar" file.
  [edited-directory]:
    Directory with the edited files, same structure as the JAR when unziped.
  [output-file]:
    Patched ".jar" file.
```

## Future work

- [ ] Support ZIP/JAR instead of a directory when diffing;
- [ ] Shellcheck;
- [ ] Support extra directory with replacements for binary files.
