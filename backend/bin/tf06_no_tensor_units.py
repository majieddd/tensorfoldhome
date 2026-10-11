"""Run TensorFold 0.6's CLI as if the GPU predates M5's Metal 4 tensor units.

TensorFold 0.6.6's M5 lane kernels fail to compile on macOS 26.2 ('unknown type name uint4b_format'),
so this routes it to the decoder it uses on M1-M4 GPUs. Usage: tf06/bin/python bench/tf06_no_tensor_units.py serve ...
"""
import sys
from tensorfold.kernels import device

device.generation = lambda: 16
device.tensor_units = lambda: False

from tensorfold.cli import main

sys.exit(main())
