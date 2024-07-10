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
