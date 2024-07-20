# npy-out

A Zig library providing write-only support for the [NPY file
format](https://numpy.org/devdocs/reference/generated/numpy.lib.format.html).

## Features

* Slices of primitive types like `f32` or `u64` are supported using corresponding NumPy data types.
* Structures are supported and encoded as NumPy structured arrays as long as the structure is
  `packed` or `extern` and has a corresponding NumPy representation.
* Multi-dimensional arrays are supported.
* Zig `u8` arrays with 0 as sentinel are encoded as NumPy byte string types (e.g. `|S10`).
* Appending to an existing or an already-opened file is supported.
* NPZ files are supported using an included ZIP file writer with optional "deflate" compression.

## Examples

* `./examples/array.zig` - basic usage, saves a 1D array of `f32` to a file.
* `./examples/sensor.zig` - writes a structure with a timestamp and some floats every second;
  demonstrates the use of structures, `DateTime64`, and incremental writing.
