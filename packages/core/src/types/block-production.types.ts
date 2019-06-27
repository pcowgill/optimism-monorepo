/* External Imports */
import BigNumber = require('bn.js')

/* Internal Imports */
import { AbiStateUpdate } from '../app'

export interface MerkleIntervalTreeNode {
  hash: Buffer // Hash of the sibling or leaf data.
  start: Buffer // The start interval value for this node.
  data: Buffer // Concatenation of (hash, index)
}

export interface MerkleIntervalInclusionProof {
  siblings: MerkleIntervalTreeNode[] // The siblings along the merkle path leading from the leaf to the root.
  leafPosition: BigNumber // The index of the leaf we are proving inclusion of.
}

export interface MerkleIntervalProofOutput {
  root: MerkleIntervalTreeNode // the root node resulting from a merkle index tree inclusion proof
  maxEnd: BigNumber // The upper bound that an inclusion proof is valid for.  
  // For a single MerkleIntervalTree, it is mathematically impossible for two branches to exist 
  // such that their [leaf.lowerBound, proofOutput.upperBound) ranges intersect.
}

export interface MerkleIntervalTree {
  dataBlocks: any // The blocks of data we are constructing a merkle interval tree for.
  levels: MerkleIntervalTreeNode[][] // The 'MerkleIntervalTreeNode's which make up the tree. levels[0].length == 
  root(): MerkleIntervalTreeNode
  getInclusionProof(leafposition: number): MerkleIntervalInclusionProof
}

export interface SubtreeContents {
  assetId: Buffer
  stateUpdates: AbiStateUpdate[]
}

export interface DoubleMerkleIntervalTree extends MerkleIntervalTree {
  dataBlocks: SubtreeContents
  subtrees: MerkleIntervalTree[]
  getStateUpdateInclusionProof(
    stateUpdatePosition: number,
    assetIdPosition: number
  ): DoubleMerkleInclusionProof
}

export interface DoubleMerkleInclusionProof {
  stateTreeInclusionProof: MerkleIntervalInclusionProof
  assetTreeInclusionProof: MerkleIntervalInclusionProof
}
