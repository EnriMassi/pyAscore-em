# distutils: language = c++
import cython
import numpy as np
cimport numpy as np

from Ascore cimport Ascore, ScoreContainer
from ModifiedPeptide cimport ModifiedPeptide
from Spectra cimport BinnedSpectra

from libcpp.vector cimport vector

cdef class PyAscore:
    """
    The PyAscore object scores the localization of post translational modifications (PTMs).

    Objects are designed to take in a spectra, the associated peptide sequence, a set of fixed 
    position modifications, and a variable amount of unlocalized modifications and determine
    how much evidence exists for placing PTMs on individual amino acids. The algorithm is a 
    modified version of Beausoleil et al. [PMID: 16964243] which can efficiently handle any
    size peptide and arbitrary PTM masses. Each scored PSM will generate the most likely PTM
    positions and scores, as well as alternative sites for each PTM which have equal evidence
    but evidence that is less than or equal to the maximum. These alternative sites are not 
    required to be adjacent (i.e. not separated by another modifiable residue).

    Note:
        Attributes are only meaningful after consumption of the first peptide.

    Parameters
    ----------
    bin_size : float
        Size in MZ of each bin
    n_top : int
        Number of top peaks to retain in each bin (must be >= 0)
    mod_group : str
        A string which lists the possible modified residues for the unlocalized modification. For example, 
        with phosphorylation, you may want "STY".
    mod_mass : float
        The mass of the unlocalized modification in Daltons. For example, phosphorylation is 79.966331.
    mz_error : float
        The error in daltons to match theoretical peaks to consumed spectral peaks. The option to use PPM
        will likely be included in the future. (Defaults to 0.5)

    Attributes
    ----------
    best_sequence : str
        Peptide sequence with modifications included in brackets for the best scoring localization.
    best_score : float
        The best Pep score among all possible localization permutations.
    ascores : ndarray of float32
        Ascores for each individual non-static site in the peptide.
    alt_sites : list of ndarry of uint32
        Alternative positions for each individual non-static site in the peptide.
    """
    cdef Ascore * ascore_ptr
    cdef ModifiedPeptide * modified_peptide_ptr
    cdef BinnedSpectra * binned_spectra_ptr

    def __cinit__(self, float bin_size, size_t n_top,
                        str mod_group, float mod_mass,
                        float mz_error=.5):
        self.binned_spectra_ptr = new BinnedSpectra(bin_size, n_top)
        self.modified_peptide_ptr = new ModifiedPeptide(mod_group.encode("utf8"), 
                                                        mod_mass, 
                                                        mz_error)
        self.ascore_ptr = new Ascore()

    def __dealloc__(self):
        del self.binned_spectra_ptr
        del self.modified_peptide_ptr
        del self.ascore_ptr

    def add_neutral_loss(self, str group, float mass):
        self.modified_peptide_ptr[0].addNeutralLoss(group.encode("utf8"), mass)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def score(self, np.ndarray[double, ndim=1, mode="c"] mz_arr not None, 
                    np.ndarray[double, ndim=1, mode="c"] int_arr not None,
                    str peptide, size_t n_of_mod,
                    np.ndarray[np.uint32_t, ndim=1, mode="c"] aux_mod_pos = None,
                    np.ndarray[np.float32_t, ndim=1, mode="c"] aux_mod_mass = None):
        """Consumer spectra and associated peptide information and score PTM localization

        Parameters
        ----------
        mz_arr : ndarray of float64
            Array of MZ values for each peak in a spectra.
        int_arr : ndarray of float64
            Array of intensity values for each peak in a spectra.
        peptide : str
            The peptide string without any modifications or n-terminal markings.
        n_of_mod : int > 0
            Number of unlocalized modifications on the sequence.
        aux_mod_pos : ndarray of uint32
            Positions of fixed modifications. Most modification positions should start at 1 with 0 being
            reserved for n-terminal modifications, as seems to be the field prefered encoding.
        aux_mod_mass : ndarray of float32
            Masses of individual fixed postion modifications.
        """ 
        # Consume spectra and bin
        self.binned_spectra_ptr[0].consumeSpectra(&mz_arr[0], &int_arr[0], mz_arr.size)

        # Build modified peptide with or without constant mods
        if aux_mod_pos is not None and aux_mod_mass is not None:
            self.modified_peptide_ptr[0].consumePeptide(peptide.encode("utf8"), n_of_mod,
                                                        &aux_mod_pos[0], &aux_mod_mass[0],
                                                        aux_mod_pos.size)
        else:
            self.modified_peptide_ptr[0].consumePeptide(peptide.encode("utf8"), n_of_mod)
        
        # Allow modified peptide to consume peaks from binned spectra
        while (self.binned_spectra_ptr[0].getBin() < self.binned_spectra_ptr[0].getNBins()):

            self.binned_spectra_ptr[0].resetRank()
            while (self.binned_spectra_ptr[0].getRank() < self.binned_spectra_ptr[0].getNPeaks()):
                self.modified_peptide_ptr[0].consumePeak(self.binned_spectra_ptr[0].getMZ(),
                                                         self.binned_spectra_ptr[0].getRank())
                self.binned_spectra_ptr[0].nextRank()

            self.binned_spectra_ptr[0].nextBin()

        self.ascore_ptr[0].score(self.binned_spectra_ptr[0], self.modified_peptide_ptr[0])

    @property
    def best_sequence(self):
        return self.ascore_ptr[0].getBestSequence().decode("utf8")

    @property
    def best_score(self):
        return self.ascore_ptr[0].getBestScore()

    @property
    def pep_scores(self):
        cdef vector[ScoreContainer] raw_score_conts = self.ascore_ptr[0].getAllPepScores();
        cdef vector[string] sequences = self.ascore_ptr[0].getAllSequences();

        proc_score_conts = []
        cdef size_t i, j
        for i in range(raw_score_conts.size()):
            score_cont = {}

            score_cont["signature"] = []
            for j in range(raw_score_conts[i].signature.size()):
                score_cont["signature"].append(raw_score_conts[i].signature[j])

            score_cont["counts"] = []
            score_cont["scores"] = []
            for j in range(raw_score_conts[i].counts.size()):
                score_cont["counts"].append(raw_score_conts[i].counts[j])
                score_cont["scores"].append(raw_score_conts[i].scores[j])

            score_cont["weighted_score"] = raw_score_conts[i].weighted_score
            score_cont["total_fragments"] = raw_score_conts[i].total_fragments
            score_cont["sequence"] = sequences[i]
            proc_score_conts.append(score_cont)

        return proc_score_conts;

    @property
    def ascores(self):
        cdef vector[float] score_vector = self.ascore_ptr[0].getAscores()
        cdef np.ndarray[float, ndim=1, mode="c"] score_array = np.zeros(
            score_vector.size(), dtype=np.float32
        )

        cdef size_t i = 0
        for i in range(score_vector.size()):
            score_array[i] = score_vector[i]
        return score_array

    @property
    def alt_sites(self):
        cdef size_t nmods
        cdef size_t mod_ind
        cdef size_t alt_ind
        
        cdef vector[size_t] alt_vector
        cdef np.ndarray[np.uint32_t, ndim=1, mode="c"] alt_array

        alt_site_list = []

        n_mods = self.modified_peptide_ptr[0].getNumberOfMods()
        for mod_ind in range(n_mods):
            alt_vector = self.ascore_ptr[0].getAlternativeSites(mod_ind)

            alt_array = np.zeros( alt_vector.size(), dtype=np.uint32 )
            
            for alt_ind in range(alt_vector.size()):
                alt_array[alt_ind] = alt_vector[alt_ind]

            alt_site_list.append(alt_array)

        return alt_site_list
