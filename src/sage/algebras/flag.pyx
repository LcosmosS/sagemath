r"""
TODO for this:

from the theory should only receive "signature"
"signature" ideally contains information about the symmetry group of the components.

Preferably this should all be cython, so it is all fast

For the identifier:
-place blocks in standard form
--sorted when the symbol is unordered
-build a canonical graph based on signature
--with bliss directly
-get a relabeling after canonical label is calculated
-store some small canonical value for later equality tests (or could relabel itself)

For the generator:
-calculate all extensions from previous and excluded data
-merge signatures
--for the above both: loop through unique relabels of a structure
-generate primitives quickly
--using nauty directly
-check excluded

For patterns:
-make no-edge mean optional by default
-make it use the block standard form and the nonisom permutator

Perhaps sanity checks when a flag is defined?
Perhaps do that in combi theory? And know that flags defined here are correct?



"""


r"""
Implementation of Flag, elements of :class:`CombinatorialTheory`

AUTHORS:

- Levente Bodnar (Dec 2023): Initial version

"""

# ****************************************************************************
#       Copyright (C) 2023 LEVENTE BODNAR <bodnalev at gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  https://www.gnu.org/licenses/
# ****************************************************************************

import itertools
from sage.rings.rational_field import QQ
from cysignals.signals cimport sig_check
from sage.structure.element cimport Element
from sage.graphs.bliss cimport canonical_form_from_edge_list

cdef list _subblock_helper(list points, list block):
    cdef bint gd = False
    cdef list ret = []
    if len(block)==0:
        return ret
    for xx in block:
        gd = True
        for yy in xx:
            if yy not in points:
                gd = False
                break
        if gd:
            cdef int ii
            ret.append([points.index(ii) for ii in xx])
    return ret

cdef bint _block_consistency(list block, list missing):
    for xx in block:
        if xx in missing:
            return False
    return True

cdef bint _block_refinement(list block0, list missing0, list block1, list missing1):
    for xx in block0:
        if xx not in block1:
            return False
    for yy in block1:
        if yy in missing0:
            return False
    for zz in missing0:
        if zz not in missing1:
            return False
    return True

cdef list _format_block(list block, bint ordered):
    if ordered:
        return sorted([tuple(sorted(xx)) for xx in block])
    else:
        return sorted([tuple(xx) for xx in block])

cdef class Flag(Element):
    
    cdef int _n
    cdef int _ftype_size
    
    cdef tuple _ftype_points
    cdef tuple _not_ftype_points
    cdef dict _blocks
    cdef tuple _unique
    
    cdef Flag _ftype
    
    def __init__(self, theory, n, **params):
        self._n = int(n)
        
        if 'ftype_points' in params:
            ftype_points = params['ftype_points']
        elif 'ftype' in params:
            ftype_points = params['ftype']
        else:
            ftype_points = tuple()
        
        self._ftype_size = len(ftype_points)
        self._ftype_points = tuple(ftype_points)
        self._not_ftype_points = None
        self._blocks = {}
        for xx in theory._signature.keys():
            if xx in params:
                self._blocks[xx] = [tuple(yy) for yy in params[xx]]
            else:
                self._blocks[xx] = list()
        self._unique = None
        self._ftype = None
        Element.__init__(self, theory)
    
    def _repr_(self):
        blocks = self.blocks()
        strblocks = ', '.join([xx+'='+str(blocks[xx]) for xx in blocks.keys()])
        if self.is_ftype():
            return 'Ftype on {} points with {}'.format(self.size(), strblocks)
        return 'Flag on {} points, ftype from {} with {}'.format(self.size(), self.ftype_points(), strblocks)
    
    def compact_repr(self):
        blocks = self.blocks()
        ret = ["n:{}".format(self.size())]
        if len(self._ftype_points)!=0:
            ret.append("t:"+"".join(map(str, self._ftype_points)))
        for name in self.theory()._signature.keys():
            desc = name + ":"
            arity = self.theory()._signature[name]
            if arity==1:
                desc += "".join([str(xx[0]) for xx in blocks[name]])
            else:
                desc += ",".join(["".join(map(str, ed)) for ed in blocks[name]])
            ret.append(desc)
        return "; ".join(ret)
    
    def raw_numbers(self):
        numbers = [self.size()] + self.ftype_points() + [15]
        blocks = self.blocks()
        for xx in blocks:
            for yy in blocks[xx]:
                numbers += yy
            numbers.append(15)
        return numbers
    
    def combinatorial_theory(self):
        r"""
        Returns the combinatorial theory this flag is a member of
        
        This is the same as the parent.

        .. SEEALSO::

            :func:`theory`
            :func:`parent`
        """
        return self.parent()
    
    theory = combinatorial_theory
    
    def as_flag_algebra_element(self, basis=QQ):
        r"""
        Transforms this `Flag` to a `FlagAlgebraElement` over a given basis

        INPUT:

        - ``basis`` -- Ring (default: `QQ`); the base of
            the FlagAlgebra where the target will live.

        OUTPUT: A `FlagAlgebraElement` representing this `Flag`

        .. SEEALSO::

            :class:`FlagAlgebra`
            :func:`FlagAlgebra._element_constructor_`
            :class:`FlagAlgebraElement`
        """
        from sage.algebras.flag_algebras import FlagAlgebra
        targ_alg = FlagAlgebra(basis, self.theory(), self.ftype())
        return targ_alg(self)
    
    afae = as_flag_algebra_element
    
    def as_operand(self):
        r"""
        Turns this `Flag` into a `FlagAlgebraElement` so operations can be performed on it

        .. SEEALSO::

            :func:`as_flag_algebra_element`
        """
        return self.afae(QQ)
    
    cpdef size(self):
        r"""
        Returns the size of the vertex set of this Flag.

        OUTPUT: integer, the number of vertices.

        EXAMPLES::

        This is the size parameter in the `Flag` initialization ::

            sage: from sage.algebras.flag_algebras import *
            sage: GraphTheory(4).size()
            4
        """
        return self._n
    
    vertex_number = size

    cpdef blocks(self, as_tuple=False, key=None, standard=False):
        r"""
        Returns the blocks

        INPUT:

        - ``as_tuple`` -- boolean (default: `False`); if the result should
            contain the blocks as a tuple

        OUTPUT: A dictionary, one entry for each element in the signature
            and list (or tuple) of the blocks for that signature.
        """
        if key==None:
            if not standard and not as_tuple:
                return self._blocks
            ret = {}
            for key in self._blocks:
                if standard:
                    bl = _format_block(self._blocks[key], self.theory().signature()[key]["ordered"])
                else:
                    bl = [tuple(xx) for xx in self._blocks[key]]
                if as_tuple:
                    ret[key] = tuple(bl)
                else:
                    ret[key] = bl
            return ret
        else:
            ret = None
            if standard:
                ret = _format_block(self._blocks[key], self.theory().signature()[key]["ordered"])
            else:
                ret = self._blocks[key]
            if as_tuple:
                return tuple(ret)
            else:
                return ret

    cpdef Flag subflag(self, points=None, ftype_points=None):
        r"""
        Returns the induced subflag.
        
        The resulting sublaf contains the union of points and ftype_points
        and has ftype constructed from ftype_points. 

        INPUT:

        - ``points`` -- list (default: `None`); the points inducing the subflag.
            If not provided (or `None`) then this is the entire vertex set, so
            only the ftype changes
        - ``ftype_points`` list (default: `None`); the points inducing the ftype
            of the subflag. If not provided (or `None`) then the original ftype
            point set is used, so the result of the ftype will be the same

        OUTPUT: The induced sub Flag

        EXAMPLES::

        Same ftype ::

            sage: from sage.algebras.flag_algebras import *
            sage: g = GraphTheory(3, edges=[[0, 1]], ftype=[0])
            sage: g.subflag([0, 2])
            Flag on 2 points, ftype from [0] with edges=[]
            
        Only change ftype ::
            
            sage: g.subflag(ftype_points=[0, 1])
            Flag on 3 points, ftype from [0, 1] with edges=[[0, 1]]

        .. NOTE::

            As the ftype points can be chosen, the result can have different
            ftype as self.

        TESTS::

            sage: g.subflag()==g
            True
        """
        cdef int ii
        if ftype_points==None:
            ftype_points = self._ftype_points
        
        if points==None:
            points = list(range(self._n))
        else:
            points = [ii for ii in range(self._n) if (ii in points or ii in ftype_points)]
        if len(points)==self._n and ftype_points==self._ftype_points:
            return self
        blocks = {xx: _subblock_helper(points, self._blocks[xx]) for xx in self._blocks.keys()}
        new_ftype_points = [points.index(ii) for ii in ftype_points]
        return self.__class__(self.parent(), len(points), ftype=new_ftype_points, **blocks)
    
    cpdef tuple ftype_points(self):
        r"""
        The points of the ftype inside self.
        
        This gives an injection of ftype into self

        OUTPUT: list of integers

        EXAMPLES::

            sage: from sage.algebras.flag_algebras import *
            sage: two_pointed_triangle = GraphTheory(3, edges=[[0, 1], [0, 2], [1, 2]], ftype=[0, 1])
            sage: two_pointed_triangle.ftype_points()
            [0, 1]

        .. SEEALSO::

            :func:`__init__`
        """
        return self._ftype_points

    cpdef tuple not_ftype_points(self):
        r"""
        This is a helper function, caches the points that are not
        part of the ftype.
        """
        if self._not_ftype_points != None:
            return self._not_ftype_points
        cdef int ii
        self._not_ftype_points = tuple([ii for ii in range(self.size()) if ii not in self._ftype_points])
        return self._not_ftype_points

    cpdef Flag ftype(self):
        r"""
        Returns the ftype of this `Flag`

        EXAMPLES::

        Ftype of a pointed triangle is just a point ::

            sage: from sage.algebras.flag_algebras import *
            sage: pointed_triangle = GraphTheory(3, edges=[[0, 1], [0, 2], [1, 2]], ftype=[0])
            sage: pointed_triangle.ftype()
            Ftype on 1 points with edges=[]
        
        And with two points it is ::
        
            sage: two_pointed_triangle = GraphTheory(3, edges=[[0, 1], [0, 2], [1, 2]], ftype=[0, 1])
            sage: two_pointed_triangle.ftype()
            Ftype on 2 points with edges=[[0, 1]]

        .. NOTE::

            This is essentially the subflag, but the order of points matter. The result is saved
            for speed.

        .. SEEALSO::

            :func:`subflag`
        """
        if self._ftype==None:
            if self.is_ftype():
                self._ftype = self
            self._ftype = self.subflag([])
        return self._ftype
    
    cpdef bint is_ftype(self):
        r"""
        Returns `True` if this flag is an ftype.

        .. SEEALSO::

            :func:`_repr_`
        """
        return self._n == self._ftype_size
    
    def canonical_relabel(self):
        cdef dict blocks = self._blocks
        cdef int next_vertex = self._n
        cdef dict signature = self.theory().signature()

        #Data for relations
        cdef dict rel_info
        cdef str rel_name
        cdef int group
        cdef bint ordered

        #
        #Creating lookup tables for the vertices/groups
        #
        cdef dict unary_relation_vertices = {}
        cdef dict tuple_vertices = {}
        cdef dict group_vertices = {}
        cdef set groups = {}
        for rel_name in signature:
            rel_info = signature[rel_name]
            arity = rel_info['arity']
            group = rel_info['group']

            #Layer 1 vertices for the relations
            if arity == 1:
                unary_relation_vertices[rel_name] = next_vertex
                next_vertex += 1
            else:
                occurrences = blocks[rel_name]
                tuple_vertices[rel_name] = {}
                for t in occurrences:
                    tuple_vertices[rel_name][t] = next_vertex
                    next_vertex += 1
            
            #Creating groups
            if group not in groups:
                groups[group] = [rel_name]
            else:
                groups[group].append(rel_name)
            #Layer 2 vertices
            group_vertices[rel_name] = next_vertex
            next_vertex += 1

        #Creating the partition, first the vertices from layer 0
        cdef list partition = [list(range(self._n))]
        for group in groups:
            #Layer 2 partition
            partition.append([group_vertices[rel_name] for rel_name in group])

            #Layer 1 partition
            cdef list group_relation_vertices = []
            for rel_name in groups[group]:
                if rel_name in unary_relation_vertices:
                    group_relation_vertices.append(unary_relation_vertices[rel_name])
                else:
                    group_relation_vertices += list(tuple_vertices[rel_name].values())
            partition.append(group_relation_vertices)

        # Build the edge lists
        cdef list Vout = []
        cdef list Vin = []
        cdef list labels = []
        cdef int max_edge_label = 0
        cdef tuple t
        cdef list conns

        
        for rel_name in unary_relation_vertices:
            #This will find connections to unary_relation_vertices[rel_name] in Layer 1

            #From layer 0
            conns = [t[0] for t in blocks[rel_name]]
            #From layer 2
            conns.append(group_vertices[rel_name])
            Vout += conns
            Vin += [unary_relation_vertices[rel_name]] * len(conns)

        for rel_name in tuple_vertices:
            #Same but for every element in unary_relation_vertices[rel_name]
            rel_info = signature[rel_name]
            ordered = rel_info['ordered']
            arity = rel_info['arity']

            #If this is the first time we realize things must be ordered
            if ordered:
                if max_edge_label==0:
                    labels = [0]*len(Vin)
                max_edge_label = max(max_edge_label, arity+2)
            
            for block in tuple_vertices[rel_name]:
                conns = [group_vertices[rel_name]] + list(block)
                Vout += conns
                Vin += [tuple_vertices[rel_name][block]] * len(conns)
                if ordered:
                    labels += list(range(1, len(conns)+1))
                elif max_edge_label>0:
                    labels += [0] * len(conns)

        
        cdef int Vnr = next_vertex
        cdef int Lnr = max_edge_label
        
        cdef tuple result = canonical_form_from_edge_list(\
        Vnr, Vout, Vin, Lnr, labels, partition, False, True)
        #new edges is good for a unique identifier
        cdef tuple new_edges = tuple(result[0])
        cdef dict relabel = result[1]
        relabel = {i: relabel[i] for i in range(n)}
        return new_edges, relabel

    cdef tuple unique(self, weak=False):
        cdef list parts = []
        cdef int ii
        cdef int next_num = 0
        if weak:
            parts = [self._ftype_points, self._not_ftype_points]
        else:
            parts = [[ii] for ii in self._ftype_points] + [self._not_ftype_points]
        next_num = self.size()
        for kk in self.theory().signature().keys():
            
            

            if self.theory().signature()[kk]["arity"]==1:
                parts.append(next_num)
                next_num += 1
            else:
                edge_points.append()
        verts += self.theory().signature_graph().size()
        cdef list parts = []
        if weak:
            parts = [self._ftype_points, self._not_ftype_points, ]

        if weak:
            return self.theory().identify(self._n, [self._ftype_points], **self._blocks)
        if self._unique==():
            self._unique = self.theory().identify(
                self._n, self._ftype_points, **self._blocks)
        return self._unique
    
    cpdef weak_equal(self, Flag other):
        return self.unique(weak=True) == other.unique(weak=True)
    
    cpdef normal_equal(self, Flag other):
        return self.unqiue() == other.unique()
    
    cpdef strong_equal(self, Flag other):
        return self.blocks(standard=True) == other.blocks(standard=True)
    
    def _add_(self, other):
        r"""
        Add two Flags together
        
        The flags must have the same ftype. Different sizes are 
            all shifted to the larger one.

        OUTPUT: The :class:`FlagAlgebraElement` object, 
            which is the sum of the two parameters

        EXAMPLES::

        Adding to self is 2*self ::

            sage: from sage.algebras.flag_algebras import *
            sage: g = GraphTheory(3)
            sage: g+g==2*g
            True
        
        Adding two distinct elements with the same size gives a vector 
        with exactly two `1` entries ::

            sage: h = GraphTheory(3, edges=[[0, 1]])
            sage: (g+h).values()
            (1, 1, 0, 0)
        
        Adding with different size the smaller flag
        is shifted to have the same size ::
        
            sage: e = GraphTheory(2)
            sage: (e+h).values()
            (1, 5/3, 1/3, 0)

        .. SEEALSO::

            :func:`FlagAlgebraElement._add_`
            :func:`__lshift__`

        """
        if self.ftype()!=other.ftype():
            raise TypeError("The terms must have the same ftype")
        return self.afae()._add_(other.afae())
    
    def _sub_(self, other):
        r"""
        Subtract a Flag from `self`
        
        The flags must have the same ftype. Different sizes are 
            all shifted to the larger one.

        EXAMPLES::
            
            sage: from sage.algebras.flag_algebras import *
            sage: g = GraphTheory(2)
            sage: h = GraphTheory(3, edges=[[0, 1]])
            sage: (g-h).values()
            (1, -1/3, 1/3, 0)

        .. SEEALSO::

            :func:`_add_`
            :func:`__lshift__`
            :func:`FlagAlgebraElement._sub_`

        """
        if self.ftype()!=other.ftype():
            raise TypeError("The terms must have the same ftype")
        return self.afae()._sub_(other.afae())
    
    def _mul_(self, other):
        r"""
        Multiply two flags together.
        
        The flags must have the same ftype. The result
        will have the same ftype and size 
        `self.size() + other.size() - self.ftype().size()`

        OUTPUT: The :class:`FlagAlgebraElement` object, 
            which is the product of the two parameters

        EXAMPLES::

        Pointed edge multiplied by itself ::

            sage: from sage.algebras.flag_algebras import *
            sage: pe = GraphTheory(2, edges=[[0, 1]], ftype=[0])
            sage: (pe*pe).values()
            (0, 0, 0, 0, 1, 1)

        .. SEEALSO::

            :func:`FlagAlgebraElement._mul_`
            :func:`mul_project`
            :func:`CombinatorialTheory.mul_project_table`

        TESTS::

            sage: sum((pe*pe*pe*pe).values())
            11
            sage: e = GraphTheory(2)
            sage: (e*e).values()
            (1, 2/3, 1/3, 0, 2/3, 1/3, 0, 0, 1/3, 0, 0)
        """
        if self.ftype()!=other.ftype():
            raise TypeError("The terms must have the same ftype")
        return self.afae()._mul_(other.afae())
    
    def __lshift__(self, amount):
        r"""
        `FlagAlgebraElement`, equal to this, with size is shifted by the amount

        EXAMPLES::

        Edge shifted to size `3` ::

            sage: from sage.algebras.flag_algebras import *
            sage: edge = GraphTheory(2, edges=[[0, 1]])
            sage: (edge<<1).values()
            (0, 1/3, 2/3, 1)

        .. SEEALSO::

            :func:`FlagAlgebraElement.__lshift__`
        """
        return self.afae().__lshift__(amount)
    
    def __truediv__(self, other):
        r"""
        Divide by a scalar

        INPUT:

        - ``other`` -- number; any number such that `1` can be divided with that

        OUTPUT: The `FlagAlgebraElement` resulting from the division

        EXAMPLES::

        Divide by `2` ::

            sage: from sage.algebras.flag_algebras import *
            sage: g = GraphTheory(3)
            sage: (g/2).values()
            (1/2, 0, 0, 0)
            
        Even for `x` symbolic `1/x` is defined, so the division is understood ::
            sage: var('x')
            x
            sage: g = GraphTheory(2)
            sage: g/x
            Flag Algebra Element over Symbolic Ring
            1/x - Flag on 2 points, ftype from [] with edges=[]
            0   - Flag on 2 points, ftype from [] with edges=[[0, 1]]
        
        .. NOTE::

            Dividing by `Flag` or `FlagAlgebraElement` is not allowed, only
            numbers such that the division is defined in some extension
            of the rationals.

        .. SEEALSO::

            :func:`FlagAlgebraElement.__truediv__`
        """
        return self.afae().__truediv__(other)
    
    def __eq__(self, other):
        r"""
        Compare two flags for == (equality)
        
        This is the isomorphism defined by the identifiers,
        respecting the types.

        .. SEEALSO::

            :func:`unique`
            :func:`theory`
            :func:`CombinatorialTheory.identify`
        """
        if type(other)!=type(self):
            return False
        if self.parent()!=other.parent():
            return False
        return self.unique() == other.unique()
    
    def __lt__(self, other):
        r"""
        Compare two flags for < (proper induced inclusion)
        
        Returns true if self appears as a proper induced structure 
        inside other.

        .. SEEALSO::

            :func:`__le__`
        """
        if type(other)!=type(self):
            return False
        if self.parent()!=other.parent():
            return False
        if self.size()>=other.size():
            return False
        if self.ftype() != other.ftype():
            return False
        for subp in itertools.combinations(other.not_ftype_points(), self.size()-self.ftype().size()):
            sig_check()
            osub = other.subflag(subp)
            if osub==None or osub.unique()==None:
                continue
            if osub.unique()==self.unique():
                return True
        return False
    
    def __le__(self, other):
        r"""
        Compare two flags for <= (induced inclusion)
        
        Returns true if self appears as an induced structure inside
        other.

        EXAMPLES::

        Edge appears in a 4 star ::

            sage: from sage.algebras.flag_algebras import *
            sage: star = GraphTheory(4, edges=[[0, 1], [0, 2], [0, 3]])
            sage: edge = GraphTheory(2, edges=[[0, 1]])
            sage: edge <= star
            True
            
        The ftypes must agree ::
        
            sage: p_edge = GraphTheory(2, edges=[[0, 1]], ftype_points=[0])
            sage: p_edge <= star
            False
        
        But when ftypes agree, the inclusion must respect it ::
            
            sage: pstar = star.subflag(ftype_points=[0])
            sage: sub1 = GraphTheory(3, ftype=[0], edges=[[0, 1], [0, 2]])
            sage: sub1 <= pstar
            True
            sage: sub2 = GraphTheory(3, ftype=[1], edges=[[0, 1], [0, 2]])
            sage: sub2 <= pstar
            False

        .. SEEALSO::

            :func:`__lt__`
            :func:`__eq__`
            :func:`unique`
        """
        return self==other or self<other
    
    def __hash__(self):
        r"""
        A hash based on the unique identifier
        so this is compatible with `__eq__`.
        """
        return hash(self.unique())
    
    def __getstate__(self):
        r"""
        Saves this flag to a dictionary
        """
        dd = {'theory': self.theory(),
              'n': self._n, 
              'ftype_points': self._ftype_points, 
              'blocks':self._blocks, 
              'unique':self._unique}
        return dd
    
    def __setstate__(self, dd):
        r"""
        Loads this flag from a dictionary
        """
        self._set_parent(dd['theory'])
        self._n = dd['n']
        self._ftype_points = dd['ftype_points']
        self._ftype_size = len(self._ftype_points)
        self._not_ftype_points = None
        self._blocks = dd['blocks']
        self._unique = dd['unique']
    
    def project(self, ftype_inj=tuple()):
        r"""
        Project this `Flag` to a smaller ftype
        

        INPUT:

        - ``ftype_inj`` -- tuple (default: (, )); the injection of the
            projected ftype inside the larger ftype

        OUTPUT: the `FlagAlgebraElement` resulting from the projection

        EXAMPLES::

        If the center of a cherry is flagged, then the projection has
        coefficient 1/3 ::

            sage: from sage.algebras.flag_algebras import *
            sage: p_cherry = GraphTheory(3, edges=[[0, 1], [0, 2]], ftype_points=[0])
            sage: p_cherry.project().values()
            (0, 0, 1/3, 0)

        .. NOTE::

            If `ftype_inj==tuple(range(self.ftype().size()))` then this
            does nothing.

        .. SEEALSO::

            :func:`FlagAlgebraElement.project`
        """
        return self.afae().project(ftype_inj)
    
    def mul_project(self, other, ftype_inj=tuple()):
        r"""
        Multiply self with other, and the project the result.

        INPUT:

        - ``ftype_inj`` -- tuple (default: (, )); the injection of the
            projected ftype inside the larger ftype

        OUTPUT: the `FlagAlgebraElement` resulting from the multiplication
            and projection

        EXAMPLES::

        Pointed edge multiplied with itself and projected ::

            sage: from sage.algebras.flag_algebras import *
            sage: p_edge = GraphTheory(2, edges=[[0, 1]], ftype_points=[0])
            sage: p_edge.mul_project(p_edge).values()
            (0, 0, 1/3, 1)

        .. NOTE::

            If `ftype_inj==tuple(range(self.ftype().size()))` then this
            is the same as usual multiplication.

        .. SEEALSO::

            :func:`_mul_`
            :func:`project`
            :func:`FlagAlgebraElement.mul_project`
        """
        return self.afae().mul_project(other, ftype_inj)
    
    def density(self, other):
        r"""
        The density of self in other.
        
        Randomly choosing self.size() points in other, the
        probability of getting self.

        EXAMPLES::

        Density of an edge in the cherry graph is 2/3 ::

            sage: from sage.algebras.flag_algebras import *
            sage: cherry = GraphTheory(3, edges=[[0, 1], [0, 2]])
            sage: edge = GraphTheory(2, edges=[[0, 1]])
            sage: cherry.density(edge)
            2/3
        
        .. SEEALSO::
        
            :func:`FlagAlgebraElement.density`
        """
        safae = self.afae()
        oafae = safae.parent(other)
        return self.afae().density(other)
    
    cpdef list _ftypes_inside(self, target):
        r"""
        Returns the possible ways self ftype appears in target

        INPUT:

        - ``target`` -- Flag; the flag where we are looking for copies of self

        OUTPUT: list of Flags with ftype matching as self, not necessarily unique
        """
        cdef list ret = []
        cdef list lrp = list(range(target.size()))
        cdef tuple ftype_points
        for ftype_points in itertools.permutations(range(target.size()), self._n):
            sig_check()
            if target.subflag(ftype_points, ftype_points)==self:
                ret.append(target.subflag(lrp, ftype_points))
        return ret
    
    cpdef densities(self, int n1, list n1flgs, int n2, list n2flgs, \
    list ftype_remap, Flag large_ftype, Flag small_ftype):
        r"""
        Returns the density matrix, indexed by the entries of `n1flgs` and `n2flgs`
        
        The matrix returned has entry `(i, j)` corresponding to the possibilities of
        `n1flgs[i]` and `n2flgs[j]` inside self, projected to the small ftype. 
        
        This is the same as counting the ways we can choose `n1` and `n2` points
        inside `self`, such that the two sets cover the entire `self.size()` point
        set, and calculating the probability that the overlap induces an ftype
        isomorphic to `large_ftype` and the points sets are isomorphic to 
        `n1flgs[i]` and `n2flgs[j]`.

        INPUT:

        - ``n1`` -- integer; the size of the first flag list
        - ``n1flgs`` -- list of flags; the first flag list (each of size `n1`)
        - ``n2`` -- integer; the size of the second flag list
        - ``n2flgs`` -- list of flags; the second flag list (each of size `n2`)
        - ``ftype_remap`` -- list; shows how to remap `small_ftype` into `large_ftype`
        - ``large_ftype`` -- ftype; the ftype of the overlap
        - ``small_ftype`` -- ftype; the ftype of self

        OUTPUT: a sparse matrix corresponding with the counts

        .. SEEALSO::

            :func:`CombinatorialTheory.mul_project_table`
            :func:`FlagAlgebra.mul_project_table`
            :func:`FlagAlgebraElement.mul_project`
        """
        cdef int N = self._n
        cdef int small_size = small_ftype.size()
        cdef int large_size = large_ftype.size()
        cdef int ctr = 0
        
        cdef dict ret = {}
        cdef list small_points = self._ftype_points
        cdef int ii
        cdef int vii
        for difference in itertools.permutations(self.not_ftype_points(), large_size - small_size):
            sig_check()
            cdef list large_points = [0]*len(ftype_remap)
            for ii in range(len(ftype_remap)):
                vii = ftype_remap[ii]
                if vii<small_size:
                    large_points[ii] = small_points[vii]
                else:
                    large_points[ii] = difference[vii-small_size]
            cdef Flag ind_large_ftype = self.subflag([], ftype_points=large_points)
            if ind_large_ftype==large_ftype:
                cdef list not_large_points = [ii for ii in range(N) if ii not in large_points]
                for n1_extra_points in itertools.combinations(not_large_points, n1 - large_size):
                    cdef Flag n1_subf = self.subflag(n1_extra_points, ftype_points=large_points)
                    cdef int n1_ind
                    try:
                        n1_ind = n1flgs.index(n1_subf)
                    except ValueError:
                        raise ValueError("Could not find \n", n1_subf, "\nin the list of ", \
                                         n1, " sized flags with ", large_ftype, \
                                         ".\nThis can happen if the generator and identifier ",\
                                         "(from the current CombinatorialTheory) is incompatible, ",\
                                         "or if the theory is not heredetary")
                    
                    cdef list remaining_points = [ii for ii in not_large_points if ii not in n1_extra_points]
                    for n2_extra_points in itertools.combinations(remaining_points, n2 - large_size):
                        cdef Flag n2_subf = self.subflag(n2_extra_points, ftype_points=large_points)
                        cdef int n2_ind
                        try:
                            n2_ind = n2flgs.index(n2_subf)
                        except:
                            raise ValueError("Could not find \n", n2_subf, "\nin the list of ", \
                                             n2, " sized flags with ", large_ftype, \
                                             ".\nThis can happen if the generator and identifier ",\
                                             "(from the current CombinatorialTheory) is incompatible, ",\
                                             "or if the theory is not heredetary")
                        try:
                            ret[(n1_ind, n2_ind)] += 1
                        except:
                            ret[(n1_ind, n2_ind)] = 1
        return (len(n1flgs), len(n2flgs), ret)


cdef class Pattern(Element):
    
    cdef int _n
    cdef int _ftype_size
    
    cdef list _ftype_points
    cdef list _not_ftype_points
    cdef dict _blocks
    
    cdef Flag _ftype
    
    def __init__(self, theory, n, **params):
        self._n = int(n)
        
        if 'ftype_points' in params:
            ftype_points = params['ftype_points']
        elif 'ftype' in params:
            ftype_points = params['ftype']
        else:
            ftype_points = []
        
        self._ftype_size = len(ftype_points)
        self._ftype_points = list(ftype_points)
        self._not_ftype_points = None
        self._blocks = {}
        for xx in theory._signature.keys():
            self._blocks[xx] = []
            self._blocks[xx+"_o"] = []
            if xx in params:
                if theory._name in ["DiGraph", "Tournament", "Permutation"]:
                    self._blocks[xx] = [list(yy) for yy in params[xx]]
                else:
                    self._blocks[xx] = [sorted(list(yy)) for yy in params[xx]]
            
            for xx_opti in [xx+"_o", xx+"_optional", xx+"_opti"]:
                if xx_opti in params:
                    if theory._name in ["DiGraph", "Tournament", "Permutation"]:
                        xx_oblocks = [list(yy) for yy in params[xx_opti]]
                    else:
                        xx_oblocks = [sorted(list(yy)) for yy in params[xx_opti]]
                    
                    for ed in xx_oblocks:
                        if len(_subblock_helper(self._ftype_points, xx_oblocks))!=0:
                            raise ValueError("Can't have optional blocks in ftype")
                    self._blocks[xx+"_o"] = xx_oblocks
        self._ftype = None
        Element.__init__(self, theory)
    
    def _repr_(self):
        blocks = self.blocks()
        strblocks = ', '.join([xx+'='+str(blocks[xx]) for xx in blocks.keys() if not (len(blocks[xx])==0 and "_o" in xx)])
        return 'Pattern on {} points, ftype from {} with {}'.format(self.size(), self.ftype_points(), strblocks)
    
    __str__ = __repr__
    
    def compact_repr(self):
        blocks = self.blocks()
        ret = ["n:{}".format(self.size())]
        if len(self._ftype_points)!=0:
            ret.append("t:"+"".join(map(str, self._ftype_points)))
        for name in self.theory()._signature.keys():
            desc = name + ":"
            arity = self.theory()._signature[name]
            if arity==1:
                desc += "".join([str(xx[0]) for xx in blocks[name]])
            else:
                desc += ",".join(["".join(map(str, ed)) for ed in blocks[name]])
            ret.append(desc)
        return "; ".join(ret)
            
    
    def raw_numbers(self):
        numbers = [self.size()] + self.ftype_points() + [15]
        blocks = self.blocks()
        for xx in blocks:
            for yy in blocks[xx]:
                numbers += yy
            numbers.append(15)
        return numbers
    
    cpdef subpattern(self, points=None, ftype_points=None):
        if ftype_points==None:
            ftype_points = self._ftype_points
        
        if points==None:
            points = list(ftype_points) + [ii for ii in range(self._n) if ii not in ftype_points]
        else:
            points = list(ftype_points) + [ii for ii in points if ii not in ftype_points]
        if set(ftype_points)!=set(self._ftype_points):
            raise ValueError("Subflag for patterns is not defined with different ftype!")
        blocks = {xx: _subblock_helper(points, self._blocks[xx]) for xx in self._blocks.keys()}
        new_ftype_points = [points.index(ii) for ii in ftype_points]
        return Pattern(self.parent(), len(points), ftype=new_ftype_points, **blocks)
    
    def combinatorial_theory(self):
        return self.parent()
    
    theory = combinatorial_theory
    
    def as_flag_algebra_element(self, basis=QQ):
        return sum(self.compatible_flags())
    
    afae = as_flag_algebra_element
    
    def as_operand(self):
        return self.afae(QQ)
    
    def size(self):
        return self._n
    
    vertex_number = size
    
    cpdef blocks(self, as_tuple=False, key=None):
        reblocks = self._blocks
        if as_tuple:
            if key != None:
                return tuple([tuple(yy) for yy in reblocks[key]])
            ret = {}
            for xx in reblocks:
                ret[xx] = tuple([tuple(yy) for yy in reblocks[xx]])
            return ret
        if key!=None:
            return reblocks[key]
        return reblocks

    cpdef ftype(self):
        if self._ftype==None:
            from sage.algebras.flag import Flag
            blocks = {xx: _subblock_helper(self._ftype_points, self._blocks[xx]) for xx in self._blocks.keys()}
            self._ftype = Flag(self.parent(), len(self._ftype_points), ftype=self._ftype_points, **blocks)
        return self._ftype
    
    cpdef ftype_points(self):
        return self._ftype_points
    
    cpdef not_ftype_points(self):
        if self._not_ftype_points != None:
            return self._not_ftype_points
        self._not_ftype_points = [ii for ii in range(self.size()) if ii not in self._ftype_points]
        return self._not_ftype_points
    
    def is_ftype(self):
        return False

    def _add_(self, other):
        if self.ftype()!=other.ftype():
            raise TypeError("The terms must have the same ftype")
        return self.afae()._add_(other.afae())
    
    def _sub_(self, other):
        if self.ftype()!=other.ftype():
            raise TypeError("The terms must have the same ftype")
        return self.afae()._sub_(other.afae())
    
    def _mul_(self, other):
        if self.ftype()!=other.ftype():
            raise TypeError("The terms must have the same ftype")
        return self.afae()._mul_(other.afae())
    
    def __lshift__(self, amount):
        return self.afae().__lshift__(amount)
    
    def __truediv__(self, other):
        return self.afae().__truediv__(other)
    
    def project(self, ftype_inj=tuple()):
        return self.afae().project(ftype_inj)
    
    def mul_project(self, other, ftype_inj=tuple()):
        return self.afae().mul_project(other, ftype_inj)
    
    def density(self, other):
        safae = self.afae()
        oafae = safae.parent(other)
        return self.afae().density(other)

    cpdef is_compatible(self, other):
        if self._n > other.size():
            return False
        if self.theory() != other.theory():
            return False
        if self.ftype() != other.ftype():
            return False
        opattern = Pattern(self.parent(), other.size(), ftype=other.ftype_points(), **other.blocks())
        cdef dict sb = self.blocks()
        for perm in itertools.permutations(other.not_ftype_points(), len(self.not_ftype_points())):
            opermed = opattern.subpattern(points=perm)
            ob = opermed.blocks()
            res = all([_block_compare(sb[xx], sb[xx+"_o"], ob[xx], ob[xx+"_o"]) for xx in self.parent().signature().keys()])
            if all([_block_compare(sb[xx], sb[xx+"_o"], ob[xx], ob[xx+"_o"]) for xx in self.parent().signature().keys()]):
                return True
        return False