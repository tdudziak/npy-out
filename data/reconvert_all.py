#!/usr/bin/env python3

import os
import glob
import numpy as np

os.chdir(os.path.dirname(os.path.abspath(__file__)))

for fname in glob.glob('*.npy'):
    data = np.load(fname)
    np.save(fname, data)
    with open(fname + '.repr', 'w') as f:
        f.write(repr(data))
        f.write('\n')

# compressed files cannot be compared byte-for-byte so we just rely on the
# manual examination of the .repr file
for fname in glob.glob('*.npz'):
    data = dict(np.load(fname))
    with open(fname + '.repr', 'w') as f:
        f.write(repr(data))
        f.write('\n')
