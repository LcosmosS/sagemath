from .all__sagemath_categories import *

from sage.misc.lazy_import import lazy_import
lazy_import('sage.sets.real_set', 'RealSet')

from .disjoint_set import DisjointSet
from .finite_set_maps import FiniteSetMaps
