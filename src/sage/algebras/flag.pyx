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
from blisspy cimport canonical_form_from_edge_list

cdef tuple _subblock_helper(tuple points, tuple block):
    if len(block)==0:
        return tuple()
    cdef bint gd = False
    cdef list ret = []
    cdef int ii
    for xx in block:
        gd = True
        for yy in xx:
            if yy not in points:
                gd = False
                break
        if gd:
            ret.append([points.index(ii) for ii in xx])
    return tuple(ret)

cdef bint _block_consistency(tuple block, tuple missing):
    cdef tuple xx
    for xx in block:
        if xx in missing:
            return False
    return True

cdef bint _block_refinement(tuple block0, tuple missing0, tuple block1, tuple missing1):
    cdef tuple xx
    for xx in block0:
        if xx not in block1:
            return False
    for xx in block1:
        if xx in missing0:
            return False
    for xx in missing0:
        if xx not in missing1:
            return False
    return True

cpdef tuple _single_relation(int n, dict relation):
    cdef int arity = relation['arity']
    if n<arity:
        return tuple([tuple()])
    cdef bint ordered = relation['ordered']
    cdef tuple base = tuple(range(n-arity, n))
    cdef tuple ord_base
    cdef int ii

    if ordered:
        ord_base = tuple(itertools.permutations(base))
    else:
        ord_base = (base, )
    
    return tuple(itertools.chain.from_iterable(
        [itertools.combinations(ord_base, r) for r in range(len(ord_base) + 1)]
    ))

cdef int _get_max_arity(dict signature):
    cdef int max_arity = 0
    cdef int curr_arity
    cdef str xx
    for xx in signature:
        curr_arity = signature[xx]['arity']
        if curr_arity<1 or curr_arity>3:
            raise ValueError("For each relation, the arity must be between 1 and 3")
        max_arity = max(max_arity, curr_arity)
    return max_arity

cdef tuple _get_extensions(int n, dict signature):
    cdef int max_arity = _get_max_arity(signature)
    cdef list terms = []
    cdef str xx

    for xx in signature:
        if signature[xx]["arity"] != max_arity:
            terms.append(tuple([tuple()]))
        else:
            terms.append(_single_relation(n, signature[xx]))
    
    cdef tuple poss
    cdef list ret = []
    for poss in itertools.product(*terms):
        ret.append({xx: poss[ii] for ii,xx in enumerate(signature)})
    return tuple(ret)

cdef bint _excluded_compatible(int n, Flag flag, tuple excluded, int max_signature):
    cdef list base_points = list(range(n-max_signature, n))
    cdef Flag fexclii
    cdef Pattern pexclii
    cdef tuple extra_points
    cdef int sii
    for ii in excluded:
        if isinstance(ii, Flag):
            fexclii = ii
            sii = fexclii.size()
            if sii<max_signature:
                continue
            for extra_points in itertools.combinations(range(n-max_signature), sii-max_signature):
                if flag.subflag(points=base_points+list(extra_points))==fexclii:
                    return False
        if isinstance(ii, Pattern):
            pexclii = ii
            sii = pexclii.size()
            if sii<max_signature:
                continue
            for extra_points in itertools.combinations(range(n-max_signature), sii-max_signature):
                if pexclii.is_compatible(flag.subflag(points=base_points+list(extra_points))):
                    return False
    return True

cpdef tuple possible_mergings(int n, tuple smaller_structures, dict signature, tuple excluded):
    #TODO
    #
    # when the result size would be less then max_signature, perform the operations with one smaller
    #
    # Also for 3-graphs debug what is lost (is the lost graph considered to be equal to something else?)
    # I.e. the generator or the identifier has an issue.
    cdef int max_arity = _get_max_arity(signature)
    cdef tuple extensions = _get_extensions(n, signature)
    cdef dict ret = {}

    cdef Flag F_subf, G_subf, H_subf #each with size n-2
    cdef Flag F, G, F_permed, G_permed, H_permed #each with size n-1
    cdef Flag final_flag #each with size n
    cdef tuple F_perms, G_perms, H_perms
    cdef dict ext
    cdef dict FG_overlap, FGH_overlap, final_overlap
    cdef tuple all_perms
    cdef tuple minustwo = tuple(list(range(n-2)) + [n-1])

    cdef int ii, jj, kk
    cdef int sslen = len(smaller_structures)
    cdef tuple patt
    if max_arity==1:
        for F in smaller_structures:
            for ext in extensions:
                sig_check()
                final_overlap = _merge_blocks_0(F._blocks, ext)
                final_flag = Flag(F.theory(), n, tuple(), **final_overlap)
                if _excluded_compatible(n, final_flag, excluded, 1):
                    patt = final_flag._relation_pattern()
                    if patt not in ret:
                        ret[patt] = [final_flag]
                    elif final_flag not in ret[patt]:
                        ret[patt].append(final_flag)
    elif max_arity==2:
        # print("max arity is 2")
        # print("input values are ", n, signature)
        # print("smaller structs ", smaller_structures)
        # print("excluded is ", excluded)
        for ii, F in enumerate(smaller_structures):
            # print("current F is ", F)
            F_perms = F.nonequal_permutations()
            for G in smaller_structures[ii:]:
                # print("current G is ", G)
                G_subf = G.subflag(range(n-2))
                for F_permed in F_perms:
                    # print("current F permed is ", F_permed)
                    # print("G subflag is ", G_subf)
                    # print("F subflag is ", F_permed.subflag(range(n-2)))
                    # print("are they strong equal? ", F_permed.subflag(range(n-2)).strong_equal(G_subf))
                    if F_permed.subflag(range(n-2)).strong_equal(G_subf):
                        FG_overlap = _merge_blocks_1(F_permed._blocks, G._blocks, n-2, n-1)
                        for ext in extensions:
                            sig_check()
                            final_overlap = _merge_blocks_0(FG_overlap, ext)
                            final_flag = Flag(F.theory(), n, tuple(), **final_overlap)
                            # print("\n\nwe have a result. The components are: ")
                            # print("F_permed is ", F_permed)
                            # print("G is ", G)
                            # print("G subflag and F permed subflag is ", G_subf)
                            # print("FG overlap is ", FG_overlap)
                            # print("extension is ", ext)
                            # print("final blocks are ", final_overlap)
                            # print("the result flag is ", final_flag)
                            if _excluded_compatible(n, final_flag, excluded, 2):
                                # print("The excluded check was successful")
                                patt = final_flag._relation_pattern()
                                if patt not in ret:
                                    ret[patt] = [final_flag]
                                elif final_flag not in ret[patt]:
                                    ret[patt].append(final_flag)
    elif max_arity==3:
        all_perms = tuple([F.nonequal_permutations() for F in smaller_structures])
        for ii, F in enumerate(smaller_structures):
            F_subf = F.subflag(range(n-2))
            for jj in range(ii, sslen):
                G_perms = all_perms[jj]
                for G_permed in G_perms:
                    G_subf = G_permed.subflag(range(n-2))
                    if G_subf.strong_equal(F_subf):
                        FG_overlap = _merge_blocks_1(F._blocks, G_permed._blocks, n-2, n-1)
                        
                        #F and G_permed are compatible

                        for kk in range(jj, sslen):
                            for H_permed in all_perms[kk]:
                                if G_subf.strong_equal(H_permed.subflag(minustwo)):
                                    if H_permed.subflag(range(n-2)).strong_equal(F.subflag(minustwo)):
                                        
                                        #F, G_permed, H_permed are compatible
                                        
                                        FGH_overlap = _merge_blocks_2(FG_overlap, H_permed._blocks, n-3, n-2, n-2, n-1)
                                        for ext in extensions:
                                            sig_check()
                                            final_overlap = _merge_blocks_0(FGH_overlap, ext)
                                            final_flag = Flag(F.theory(), n, tuple(), **final_overlap)
                                            if _excluded_compatible(n, final_flag, excluded, 3):
                                                patt = final_flag._relation_pattern()
                                                if patt not in ret:
                                                    ret[patt] = [final_flag]
                                                elif final_flag not in ret[patt]:
                                                    ret[patt].append(final_flag)
    return tuple(itertools.chain.from_iterable(ret.values()))

cdef dict _merge_blocks_0(dict block0, dict block1):
    cdef dict merged = {}
    cdef str key
    for key in block0:
        merged[key] = tuple(itertools.chain(block0[key], block1[key]))
    return merged

cdef dict _merge_blocks_1(dict block0, dict block1, int from0, int to0):
    cdef dict merged = {}
    cdef str key
    cdef object terms_remapped
    cdef tuple term

    for key in block0:
        terms_remapped = (
            tuple((xx if xx != from0 else to0) for xx in term)
            for term in block1[key] if from0 in term
        )
        merged[key] = tuple(itertools.chain(block0[key], terms_remapped))
    return merged

#TODO check if the order of remaps can break if there is an overlap
cdef dict _merge_blocks_2(dict block0, dict block1, int from0, int to0, int from1, int to1):
    cdef dict merged = {}
    cdef str key
    cdef object terms_remapped
    cdef tuple term

    for key in block0:
        terms_remapped = (
            tuple(
                    (
                        (
                        xx if xx != from1 else to1
                        ) 
                        if xx != from0 else to0
                    ) for xx in term
                )
            for term in block1[key] if 
            (
                from0 in term and from1 in term
            )
        )
        merged[key] = tuple(itertools.chain(block0[key], terms_remapped))
    return merged

cdef dict _standardize_blocks(dict blocks, dict signature, bint pattern):
    cdef dict ret = {}
    cdef str xx, kk
    for xx in blocks:
        if not pattern:
            if signature[xx]["ordered"]:
                ret[xx] = tuple(sorted([tuple(yy) for yy in blocks[xx]]))
            else:
                ret[xx] = tuple(sorted([tuple(sorted(yy)) for yy in blocks[xx]]))
        else:
            kk = xx
            if xx not in signature:
                kk = xx[:-2]
            if signature[kk]["ordered"]:
                ret[xx] = tuple(sorted([tuple(yy) for yy in blocks[xx]]))
            else:
                ret[xx] = tuple(sorted([tuple(sorted(yy)) for yy in blocks[xx]]))
    return ret

cdef class Flag(Element):
    
    cdef int _n
    cdef int _ftype_size
    
    cdef tuple _ftype_points
    cdef tuple _not_ftype_points
    cdef dict _blocks
    cdef tuple _unique
    cdef tuple _weak_unique
    
    cdef Flag _ftype
    
    def __init__(self, theory, n, ftype, **params):
        self._n = int(n)
        self._ftype_points = tuple(ftype)
        self._ftype_size = len(self._ftype_points)
        self._not_ftype_points = None
        self._blocks = _standardize_blocks(params, theory._signature, False)
        self._unique = None
        self._weak_unique = None
        self._ftype = None
        Element.__init__(self, theory)
    
    def _repr_(self):
        blocks = self.blocks()
        blocks_reps = []
        for xx in blocks.keys():
            brx = xx + '=('
            bsb = []
            for ee in blocks[xx]:
                bsb.append("".join(map(str, ee)))
            brx += ' '.join(bsb)
            brx += ')'
            blocks_reps.append(brx)
        strblocks = ', '.join(blocks_reps)
        if self.is_ftype():
            return 'Ftype on {} points with {}'.format(self.size(), strblocks)
        return 'Flag on {} points, ftype from {} with {}'.format(self.size(), self.ftype_points(), strblocks)
    
    def _serialize(self):
        ret = [self.size(), self.ftype_points()]
        blocks = self.blocks()
        for kk in blocks:
            ret.append(blocks[kk])
        return tuple(ret)

    cpdef tuple _relation_pattern(self):
        cdef dict ret = {}
        cdef dict signature = self.parent().signature()
        cdef int group
        for xx in signature:
            group = signature[xx]["group"]
            if group in ret:
                ret[group].append(len(self._blocks[xx]))
            else:
                ret[group] = [len(self._blocks[xx])]
        return tuple([tuple(sorted(xx)) for xx in ret.values()])
    
    # Basic properties

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

    cpdef dict signature(self):
        return self.theory().signature()

    cpdef dict blocks(self, key=None):
        r"""
        Returns the blocks

        INPUT:

        - ``key`` -- 

        OUTPUT: 
        """
        if key==None:
            return self._blocks
        else:
            return self._blocks[key]
    
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


    # Isomorphisms and related stuff

    cpdef tuple unique(self, bint weak = False):
        if weak and self._weak_unique != None:
            return self._weak_unique
        if (not weak) and self._unique != None:
            return self._unique

        cdef tuple symmetry_graph_data = self._symmetry_graph(weak)

        cdef tuple result = canonical_form_from_edge_list(
            symmetry_graph_data[0],
            symmetry_graph_data[1],
            symmetry_graph_data[2],
            symmetry_graph_data[3],
            symmetry_graph_data[4],
            symmetry_graph_data[5], 
            True
        )
        cdef list new_edges = sorted(result[0])
        cdef tuple uniret = tuple([len(self.ftype_points()), weak] + new_edges)
        cdef dict relabel = result[1]
        relabel = {i: relabel[i] for i in range(self.size())}
        cdef tuple ret = (uniret, relabel)
        if weak:
            self._weak_unique = ret
        else:
            self._unique = ret
        return ret
    
    cdef tuple _symmetry_graph(self, bint weak = False):
        #Should return:
        #-vertex number, 
        #-edges as two lists,
        #-edge label number
        #-edge labels
        #-partition

        cdef dict blocks = self._blocks
        cdef int next_vertex = self.size()
        cdef dict signature = self.signature()
        cdef tuple symmetries = self.parent()._symmetries

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
        cdef dict groups = {}
        cdef list group_relation_vertices
        cdef tuple t
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
        cdef list partition

        if weak:
            partition = [self.ftype_points(), self.not_ftype_points()]
        else:
            partition = [[ii] for ii in self.ftype_points()]
            partition.append(self.not_ftype_points())

        for group in groups:
            #Layer 2 partition
            partition.append([group_vertices[rel_name] for rel_name in groups[group]])

            #Layer 1 partition
            group_relation_vertices = []
            for rel_name in groups[group]:
                if rel_name in unary_relation_vertices:
                    group_relation_vertices.append(unary_relation_vertices[rel_name])
                else:
                    group_relation_vertices += list(tuple_vertices[rel_name].values())
            partition.append(group_relation_vertices)

        # Build the edge lists
        cdef list Vout = []
        cdef list Vin = []
        cdef list labels = None
        cdef int edge_label_num = 1
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
            if ordered and arity!=1:
                if labels==None:
                    labels = [0]*len(Vin)
                edge_label_num = max(edge_label_num, arity)
            
            for block in tuple_vertices[rel_name]:
                conns = [group_vertices[rel_name]] + list(block)
                Vout += conns
                Vin += [tuple_vertices[rel_name][block]] * len(conns)
                if ordered and arity!=1:
                    labels += list(range(len(conns)))
                elif labels!=None:
                    labels += [0] * len(conns)
        
        cdef tuple ret = (next_vertex, Vout, Vin, edge_label_num, labels, partition)
        #print(ret)
        return ret

    def sage_symmetry_graph(self):
        symmetry_graph_data = self._symmetry_graph()
        Vnr, Vout, Vin, Lnr, labels, partition = symmetry_graph_data
        vert_inds = []
        for xx in range(Vnr):
            for ii, par in enumerate(partition):
                if xx in par:
                    vert_inds.append(ii)
        vertices = list(zip(range(Vnr), vert_inds))
        Vout = [vertices[ii] for ii in Vout]
        Vin = [vertices[ii] for ii in Vin]
        if labels==None:
            labels = [0]*len(Vin)
        edges = list(zip(Vin, Vout, labels))
        from sage.graphs.graph import Graph
        return Graph([vertices, edges], format="vertices_and_edges")

    cpdef bint weak_equal(self, Flag other):
        if self.theory() != other.theory():
            return False
        if self._ftype_size != other._ftype_size:
            return False
        cdef tuple sun = self.unique(weak=True)
        cdef tuple oun = other.unique(weak=True)
        return sun[0] == oun[0]
    
    cpdef bint normal_equal(self, Flag other):
        if self.theory() != other.theory():
            return False
        if self._ftype_size != other._ftype_size:
            return False
        cdef tuple sun = self.unique(weak=False)
        cdef tuple oun = other.unique(weak=False)
        return sun[0] == oun[0]
    
    cpdef bint strong_equal(self, Flag other):
        if self.theory() != other.theory():
            return False
        if self.ftype_points() != other.ftype_points():
            return False
        return self._blocks == other._blocks
    

    # Core loops

    cpdef Flag subflag(self, points=None, ftype_points=None):
        r"""
        Returns the induced subflag.
        """
        if len(points)==0:
            return self.parent().empty()
        cdef int ii
        if ftype_points==None:
            ftype_points = self._ftype_points
        
        if points==None:
            points = tuple(range(self._n))
        else:
            points = tuple(list(points) + [ii for ii in ftype_points if ii not in points])
        ftype_points = tuple(ftype_points)
        if points==tuple(range(self.size())) and ftype_points==self._ftype_points:
            return self
        blocks = {xx: _subblock_helper(points, self._blocks[xx]) for xx in self._blocks.keys()}
        new_ftype_points = [points.index(ii) for ii in ftype_points]
        return Flag(self.parent(), len(points), new_ftype_points, **blocks)

    cpdef list ftypes_inside(self, target):
        r"""
        Returns the possible ways self ftype appears in target

        INPUT:

        - ``target`` -- Flag; the flag where we are looking for copies of self

        OUTPUT: list of Flags with ftype matching as self, not necessarily unique
        """
        cdef list ret = []
        cdef list lrp = list(range(target.size()))
        cdef tuple ftype_points
        cdef Flag newflag
        for ftype_points in itertools.permutations(range(target.size()), self._n):
            sig_check()
            if target.subflag(ftype_points, ftype_points)==self:
                newflag = target.subflag(lrp, ftype_points)
                if newflag not in ret:
                    ret.append(newflag)
        return ret

    cpdef tuple nonequal_permutations(self):
        cdef list ret = []
        cdef tuple perm
        cdef Flag newflag
        cdef Flag xx
        cdef bint can_add
        for perm in itertools.permutations(range(self.size())):
            sig_check()
            newflag = self.subflag(points=perm)
            can_add = True
            for xx in ret:
                if xx.strong_equal(newflag):
                    can_add = False
                    break
            if can_add:
                ret.append(newflag)
        return tuple(ret)
    
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
        cdef tuple small_points = self._ftype_points
        cdef int ii, vii, n1_ind, n2_ind
        cdef tuple difference
        cdef list large_points, remaining_points, not_large_points
        cdef Flag n1_subf, n2_subf, ind_large_ftype
        for difference in itertools.permutations(self.not_ftype_points(), large_size - small_size):
            sig_check()
            large_points = [0]*len(ftype_remap)
            for ii in range(len(ftype_remap)):
                vii = ftype_remap[ii]
                if vii<small_size:
                    large_points[ii] = small_points[vii]
                else:
                    large_points[ii] = difference[vii-small_size]
            ind_large_ftype = self.subflag([], ftype_points=large_points)
            if ind_large_ftype==large_ftype:
                not_large_points = [ii for ii in range(N) if ii not in large_points]
                for n1_extra_points in itertools.combinations(not_large_points, n1 - large_size):
                    n1_subf = self.subflag(n1_extra_points, ftype_points=large_points)
                    try:
                        n1_ind = n1flgs.index(n1_subf)
                    except ValueError:
                        raise ValueError("Could not find \n", n1_subf, "\nin the list of ", \
                                         n1, " sized flags with ", large_ftype, \
                                         ".\nThis can happen if the generator and identifier ",\
                                         "(from the current CombinatorialTheory) is incompatible, ",\
                                         "or if the theory is not heredetary")
                    
                    remaining_points = [ii for ii in not_large_points if ii not in n1_extra_points]
                    for n2_extra_points in itertools.combinations(remaining_points, n2 - large_size):
                        n2_subf = self.subflag(n2_extra_points, ftype_points=large_points)
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

    # Flag algebra compatibility

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
        return self.normal_equal(other)
    
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
            if self==osub:
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
        return hash(self.unique()[0])
    
    def __getstate__(self):
        r"""
        Saves this flag to a dictionary
        """
        dd = {'theory': self.theory(),
              'n': self._n, 
              'ftype_points': self._ftype_points, 
              'blocks':self._blocks, 
              'unique':self._unique,
              'weak_unique':self._weak_unique}
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
        self._weak_unique = dd['weak_unique']
    
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
        return self.afae().density(oafae)
    

cdef class Pattern(Element):
    
    cdef int _n
    cdef int _ftype_size
    
    cdef list _ftype_points
    cdef list _not_ftype_points
    cdef dict _blocks
    
    cdef Flag _ftype
    
    def __init__(self, theory, n, ftype, **params):
        self._n = int(n)
        self._ftype_points = tuple(ftype)
        self._ftype_size = len(self._ftype_points)
        self._not_ftype_points = None
        self._blocks = _standardize_blocks(params, theory._signature, False)
        self._unique = None
        self._weak_unique = None
        self._ftype = None
        Element.__init__(self, theory)
    
    def _repr_(self):
        blocks = self.blocks()
        strblocks = ', '.join([xx+'='+str(blocks[xx]) for xx in blocks.keys()])
        return 'Pattern on {} points, ftype from {} with {}'.format(self.size(), self.ftype_points(), strblocks)
    
    __str__ = _repr_
    
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
        return Pattern(self.parent(), len(points), new_ftype_points, **blocks)
    
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
            self._ftype = Flag(self.parent(), len(self._ftype_points), self._ftype_points, **blocks)
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

    cpdef _add_(self, other):
        if self.ftype()!=other.ftype():
            raise TypeError("The terms must have the same ftype")
        return self.afae()._add_(other.afae())
    
    cpdef _sub_(self, other):
        if self.ftype()!=other.ftype():
            raise TypeError("The terms must have the same ftype")
        return self.afae()._sub_(other.afae())
    
    cpdef _mul_(self, other):
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

    cpdef bint is_compatible(self, other):
        if self._n > other.size():
            return False
        if self.theory() != other.theory():
            return False
        if self.ftype() != other.ftype():
            return False
        opattern = Pattern(self.parent(), other.size(), other.ftype_points(), **other.blocks())
        cdef dict sb = self.blocks()
        for perm in itertools.permutations(other.not_ftype_points(), len(self.not_ftype_points())):
            opermed = opattern.subpattern(points=perm)
            ob = opermed.blocks()
            if all([_block_refinement(sb[xx], sb[xx+"_o"], ob[xx], ob[xx+"_o"]) for xx in self.parent().signature().keys()]):
                return True
        return False