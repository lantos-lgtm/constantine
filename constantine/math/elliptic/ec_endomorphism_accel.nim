# Constantine
# Copyright (c) 2018-2019    Status Research & Development GmbH
# Copyright (c) 2020-Present Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard Library
  std/typetraits,
  # Internal
  ../../platforms/abstractions,
  ../config/[curves, type_bigint],
  ../curves/zoo_endomorphisms,
  ../arithmetic,
  ../extension_fields,
  ../isogenies/frobenius,
  ./ec_shortweierstrass_affine

# ############################################################
#
#             Endomorphism acceleration for
#                 Scalar Multiplication
#
# ############################################################
#
# This files implements endomorphism-acceleration of scalar multiplication
# using:
# - GLV endomorphism on G1 (Gallant-Lambert-Vanstone)
# - GLV and GLS endomorphisms on G2 (Galbraith-Lin-Scott)

# Decomposition into scalars -> miniscalars
# ----------------------------------------------------------------------------------------

type
  MultiScalar[M, LengthInBits: static int] = array[M, BigInt[LengthInBits]]
    ## Decomposition of a secret scalar in multiple scalars

func decomposeEndo*[M, scalBits, L: static int](
       miniScalars: var MultiScalar[M, L],
       negatePoints: var array[M, SecretBool],
       scalar: BigInt[scalBits],
       F: typedesc[Fp or Fp2]
     ) =
  ## Decompose a secret scalar into M mini-scalars
  ## using a curve endomorphism(s) characteristics.
  ##
  ## A scalar decomposition might lead to negative miniscalar(s).
  ## For proper handling it requires either:
  ## 1. Negating it and then negating the corresponding curve point P
  ## 2. Adding an extra bit to the recoding, which will do the right thing™
  ##
  ## For implementation solution 1 is faster:
  ##   - Double + Add is about 5000~8000 cycles on 6 64-bits limbs (BLS12-381)
  ##   - Conditional negate is about 10 cycles per Fp, on G2 projective we have 3 (coords) * 2 (Fp2) * 10 (cycles) ~= 60 cycles
  ##     We need to test the mini scalar, which is 65 bits so 2 Fp so about 2 cycles
  ##     and negate it as well.

  # Equal when no window or no negative handling, greater otherwise
  static: doAssert L >= (scalBits + M - 1) div M + 1
  const w = F.C.getCurveOrderBitwidth().wordsRequired()

  when M == 2:
    var alphas{.noInit.}: (
      BigInt[scalBits + babai(F)[0][0].bits],
      BigInt[scalBits + babai(F)[1][0].bits]
    )
  elif M == 4:
    var alphas{.noInit.}: (
      BigInt[scalBits + babai(F)[0][0].bits],
      BigInt[scalBits + babai(F)[1][0].bits],
      BigInt[scalBits + babai(F)[2][0].bits],
      BigInt[scalBits + babai(F)[3][0].bits]
    )
  else:
    {.error: "The decomposition degree " & $M & " is not configured".}

  staticFor i, 0, M:
    when bool babai(F)[i][0].isZero():
      alphas[i].setZero()
    else:
      alphas[i].prod_high_words(babai(F)[i][0], scalar, w)
    when babai(F)[i][1]:
      # prod_high_words works like logical right shift
      # When negative, we should add 1 to properly round toward -infinity
      alphas[i] += One

  # We have k0 = s - 𝛼0 b00 - 𝛼1 b10 ... - 𝛼m bm0
  # and     kj = 0 - 𝛼j b0j - 𝛼1 b1j ... - 𝛼m bmj
  var
    k: array[M, BigInt[scalBits]] # zero-init required
    alphaB {.noInit.}: BigInt[scalBits]
  k[0] = scalar
  staticFor miniScalarIdx, 0, M:
    staticFor basisIdx, 0, M:
      when not bool lattice(F)[basisIdx][miniScalarIdx][0].isZero():
        when bool lattice(F)[basisIdx][miniScalarIdx][0].isOne():
          alphaB.copyTruncatedFrom(alphas[basisIdx])
        else:
          alphaB.prod(alphas[basisIdx], lattice(F)[basisIdx][miniScalarIdx][0])

        when lattice(F)[basisIdx][miniScalarIdx][1] xor babai(F)[basisIdx][1]:
          k[miniScalarIdx] += alphaB
        else:
          k[miniScalarIdx] -= alphaB

    let isNeg = k[miniScalarIdx].isMsbSet()
    negatePoints[miniScalarIdx] = isNeg
    k[miniScalarIdx].cneg(isNeg)
    miniScalars[miniScalarIdx].copyTruncatedFrom(k[miniScalarIdx])

# Secret scalar + dynamic point
# ----------------------------------------------------------------
#
# This section targets the case where the scalar multiplication [k]P
# involves:
# - a secret scalar `k`, hence requiring constant-time operations
# - a dynamic `P`
#
# For example signing a message
#
# When P is known ahead of time (for example it's the generator)
# We can precompute the point decomposition with plain scalar multiplication
# and not require a fast endomorphism.
# (For example generating a public-key)

type
  Recoded[LengthInDigits: static int] = distinct array[(LengthInDigits + 7) div 8, byte]
  GLV_SAC[M, LengthInDigits: static int] = array[M, Recoded[LengthInDigits]]
    ## GLV-Based Sign-Aligned-Column representation
    ## see Faz-Hernandez, 2013
    ##
    ## (i) Length of every sub-scalar is fixed and given by
    ##     l = ⌈log2 r/m⌉ + 1 where r is the prime subgroup order
    ##     and m the number of dimensions of the GLV endomorphism
    ## (ii) Exactly one subscalar which should be odd
    ##      is expressed by a signed nonzero representation
    ##      with all digits ∈ {1, −1} represented at a lowlevel
    ##      by bit {0, 1} (0 bit -> positive 1 digit, 1 bit -> negative -1 digit)
    ## (iii) Other subscalars have digits  ∈ {0, 1, −1}
    ##       with 0 encoded as 0 and 1/-1 encoded as 1
    ##       and the sign taken from the sign subscalar (at position 0)
    ##
    ## Digit-Endianness is bigEndian

const
  BitSize   = 1
  Shift     = 3                    # log2(sizeof(byte) * 8) - Find the word to read/write
  WordMask  = sizeof(byte) * 8 - 1 #                        - In the word, shift to the offset to read/write
  DigitMask = 1 shl BitSize - 1    # Digits take 1-bit      - Once at location, isolate bits to read/write

proc `[]`(recoding: Recoded,
          digitIdx: int): uint8 {.inline.}=
  ## 0 <= digitIdx < LengthInDigits
  ## returns digit ∈ {0, 1}
  const len = Recoded.LengthInDigits
  # assert digitIdx * BitSize < len

  let slot = distinctBase(recoding)[
    (len-1 - digitIdx) shr Shift
  ]
  let recoded = slot shr (BitSize*(digitIdx and WordMask)) and DigitMask
  return recoded

proc `[]=`(recoding: var Recoded,
           digitIdx: int, value: uint8) {.inline.}=
  ## 0 <= digitIdx < LengthInDigits
  ## returns digit ∈ {0, 1}
  ## This is write-once, requires zero-init
  ## This works in BigEndian mode
  const len = Recoded.LengthInDigits
  # assert digitIdx * BitSize < Recoded.LengthInDigits

  let slot = distinctBase(recoding)[
    (len-1 - digitIdx) shr Shift
  ].addr

  let shifted = byte((value and DigitMask) shl (BitSize*(digitIdx and WordMask)))
  slot[] = slot[] or shifted

func nDimMultiScalarRecoding[M, L: static int](
    dst: var GLV_SAC[M, L],
    src: MultiScalar[M, L]
  ) =
  ## This recodes N scalar for GLV multi-scalar multiplication
  ## with side-channel resistance.
  ##
  ## Precondition src[0] is odd
  #
  # - Efficient and Secure Algorithms for GLV-Based Scalar
  #   Multiplication and their Implementation on GLV-GLS
  #   Curves (Extended Version)
  #   Armando Faz-Hernández, Patrick Longa, Ana H. Sánchez, 2013
  #   https://eprint.iacr.org/2013/158.pdf
  #
  # Algorithm 1 Protected Recoding Algorithm for the GLV-SAC Representation.
  # ------------------------------------------------------------------------
  #
  # We modify Algorithm 1 with the last paragraph optimization suggestions:
  # - instead of ternary coding -1, 0, 1 (for negative, 0, positive)
  # - we use 0, 1 for (0, sign of column)
  #   and in the sign column 0, 1 for (positive, negative)

  # assert src[0].isOdd - Only happen on implementation error, we don't want to leak a single bit

  var k = src # Keep the source multiscalar in registers
  template b: untyped {.dirty.} = dst

  b[0][L-1] = 0 # means positive column
  for i in 0 .. L-2:
    b[0][i] = 1 - k[0].bit(i+1).uint8
  for j in 1 .. M-1:
    for i in 0 .. L-1:
      let bji = k[j].bit0.uint8
      b[j][i] = bji
      k[j].div2()
      k[j] += SecretWord (bji and b[0][i])

func buildLookupTable[M: static int, EC, ECaff](
       P: EC,
       endomorphisms: array[M-1, EC],
       lut: var array[1 shl (M-1), ECaff],
     ) =
  ## Build the lookup table from the base point P
  ## and the curve endomorphism
  #
  # Algorithm
  # Compute P[u] = P0 + u0 P1 +...+ um−2 Pm−1 for all 0≤u<2^m−1, where
  # u= (um−2,...,u0)_2.
  #
  # Traduction:
  #   for u in 0 ..< 2^(m-1)
  #     lut[u] = P0
  #     iterate on the bit representation of u
  #       if the bit is set, add the matching endomorphism to lut[u]
  #
  # Note: This is for variable/unknown point P
  #       when P is fixed at compile-time (for example is the generator point)
  #       alternative algorithms are more efficient.
  #
  # Implementation:
  #   We optimize the basic algorithm to reuse already computed table entries
  #   by noticing for example that:
  #   - 6 represented as 0b0110 requires P0 + P2 + P3
  #   - 2 represented as 0b0010 already required P0 + P2
  #   To find the already computed table entry, we can index
  #   the table with the current `u` with the MSB unset
  #   and add to it the endomorphism at the index matching the MSB position
  #
  #   This scheme ensures 1 addition per table entry instead of a number
  #   of addition dependent on `u` Hamming Weight

  # Step 1. Create the lookup-table in alternative coordinates
  var tab {.noInit.}: array[1 shl (M-1), EC]
  tab[0] = P
  for u in 1'u32 ..< 1 shl (M-1):
    # The recoding allows usage of 2^(n-1) table instead of the usual 2^n with NAF
    let msb = u.log2_vartime() # No undefined, u != 0
    tab[u].sum(tab[u.clearBit(msb)], endomorphisms[msb])

  # Step 2. Convert to affine coordinates to benefit from mixed-addition
  lut.batchAffine(tab)

func tableIndex(glv: GLV_SAC, bit: int): SecretWord =
  ## Compose the secret table index from
  ## the GLV-SAC representation and the "bit" accessed
  staticFor i, 1, GLV_SAC.M:
    result = result or SecretWord((glv[i][bit] and 1) shl (i-1))

func secretLookup[T](dst: var T, table: openArray[T], index: SecretWord) =
  ## Load a table[index] into `dst`
  ## This is constant-time, whatever the `index`, its value is not leaked
  ## This is also protected against cache-timing attack by always scanning the whole table
  for i in 0 ..< table.len:
    let selector = SecretWord(i) == index
    dst.ccopy(table[i], selector)

func scalarMulEndo*[scalBits; EC](
       P: var EC,
       scalar: BigInt[scalBits]
     ) =
  ## Elliptic Curve Scalar Multiplication
  ##
  ##   P <- [k] P
  ##
  ## This is a scalar multiplication accelerated by an endomorphism
  ## - via the GLV (Gallant-lambert-Vanstone) decomposition on G1
  ## - via the GLS (Galbraith-Lin-Scott) decomposition on G2
  ##
  ## Requires:
  ## - Cofactor to be cleared
  ## - 0 <= scalar < curve order
  mixin affine
  type ECaff = affine(EC)
  const C = P.F.C # curve
  static: doAssert scalBits <= C.getCurveOrderBitwidth(), "Do not use endomorphism to multiply beyond the curve order"
  when P.F is Fp:
    const M = 2
    # 1. Compute endomorphisms
    var endomorphisms {.noInit.}: array[M-1, EC]
    when P.G == G1:
      endomorphisms[0] = P
      endomorphisms[0].x *= C.getCubicRootOfUnity_mod_p()
    else:
      endomorphisms[0].frobenius_psi(P, 2)

  elif P.F is Fp2:
    const M = 4
    # 1. Compute endomorphisms
    var endomorphisms {.noInit.}: array[M-1, EC]
    endomorphisms[0].frobenius_psi(P)
    endomorphisms[1].frobenius_psi(P, 2)
    endomorphisms[2].frobenius_psi(P, 3)
  else:
    {.error: "Unconfigured".}

  # 2. Decompose scalar into mini-scalars
  const L = (scalBits + M - 1) div M + 1 # Alternatively, negative can be handled with an extra "+1"
  var miniScalars {.noInit.}: array[M, BigInt[L]]
  var negatePoints {.noInit.}: array[M, SecretBool]
  miniScalars.decomposeEndo(negatePoints, scalar, P.F)

  # 3. Handle negative mini-scalars
  # A scalar decomposition might lead to negative miniscalar.
  # For proper handling it requires either:
  # 1. Negating it and then negating the corresponding curve point P
  # 2. Adding an extra bit to the recoding, which will do the right thing™
  #
  # For implementation solution 1 is faster:
  #   - Double + Add is about 5000~8000 cycles on 6 64-bits limbs (BLS12-381)
  #   - Conditional negate is about 10 cycles per Fp, on G2 projective we have 3 (coords) * 2 (Fp2) * 10 (cycles) ~= 60 cycles
  #     We need to test the mini scalar, which is 65 bits so 2 Fp so about 2 cycles
  #     and negate it as well.
  block:
    P.cneg(negatePoints[0])
    staticFor i, 1, M:
      endomorphisms[i-1].cneg(negatePoints[i])

  # 4. Precompute lookup table
  var lut {.noInit.}: array[1 shl (M-1), ECaff]
  buildLookupTable(P, endomorphisms, lut)

  # 5. Recode the miniscalars
  #    we need the base miniscalar (that encodes the sign)
  #    to be odd, and this in constant-time to protect the secret least-significant bit.
  let k0isOdd = miniScalars[0].isOdd()
  discard miniScalars[0].cadd(One, not k0isOdd)

  var recoded: GLV_SAC[M, L] # zero-init required
  recoded.nDimMultiScalarRecoding(miniScalars)

  # 6. Proceed to GLV accelerated scalar multiplication
  var Q {.noInit.}: EC
  var tmp {.noInit.}: ECaff
  tmp.secretLookup(lut, recoded.tableIndex(L-1))
  Q.fromAffine(tmp)

  for i in countdown(L-2, 0):
    Q.double()
    tmp.secretLookup(lut, recoded.tableIndex(i))
    tmp.cneg(SecretBool recoded[0][i])
    Q += tmp

  # Now we need to correct if the sign miniscalar was not odd
  P.diff(Q, P)
  P.ccopy(Q, k0isOdd)

# Windowed GLV
# ----------------------------------------------------------------
# Config
# - 2 dimensional decomposition
# - Window of size 2
# -> precomputation 2^((2*2)-1) = 8

# Encoding explanation:
# - Coding is in big endian
#   digits are grouped 2-by-2
# - k0 column has the following sign and encoding
#   - `paper` -> `impl` is `value`
#   with ternary encoding from the paper and 𝟙 denoting -1
#   -  0t1𝟙   ->  0b01  is   1
#   -  0t11   ->  0b00  is   3
#   -  0t𝟙1   ->  0b10  is  -1
#   -  0t𝟙𝟙   ->  0b11  is  -3
# - if k0 == 1 (0t1𝟙 - 0b01) or -1 (0b10 - 0t0𝟙):
#   then kn is encoded with
#     (signed opposite 2-complement)
#   -  0t00   ->  0b00  is  0
#   -  0t0𝟙   ->  0b01  is -1
#   -  0t10   ->  0b10  is  2
#   -  0t1𝟙   ->  0b11  is  1
#   if k0 == 3 (0b00) or -3 (0b11):
#   then kn is encoded with
#     (unsigned integer)
#   -  0t00   ->  0b00  is  0
#   -  0t01   ->  0b01  is  1
#   -  0t10   ->  0b10  is  2
#   -  0t11   ->  0b11  is  3

func buildLookupTable_m2w2[EC, Ecaff](
       P0: EC,
       P1: EC,
       lut: var array[8, Ecaff],
     ) =
  ## Build a lookup table for GLV with 2-dimensional decomposition
  ## and window of size 2

  # Step 1. Create the lookup-table in alternative coordinates
  var tab {.noInit.}: array[8, EC]

  # with [k0, k1] the mini-scalars with digits of size 2-bit
  #
  # 4 = 0b100 - encodes [0b01, 0b00] ≡ P0
  tab[4] = P0
  # 5 = 0b101 - encodes [0b01, 0b01] ≡ P0 - P1
  tab[5].diff(tab[4], P1)
  # 7 = 0b111 - encodes [0b01, 0b11] ≡ P0 + P1
  tab[7].sum(tab[4], P1)
  # 6 = 0b110 - encodes [0b01, 0b10] ≡ P0 + 2P1
  tab[6].sum(tab[7], P1)

  # 0 = 0b000 - encodes [0b00, 0b00] ≡ 3P0
  tab[0].double(tab[4])
  tab[0] += tab[4]
  # 1 = 0b001 - encodes [0b00, 0b01] ≡ 3P0 + P1
  tab[1].sum(tab[0], P1)
  # 2 = 0b010 - encodes [0b00, 0b10] ≡ 3P0 + 2P1
  tab[2].sum(tab[1], P1)
  # 3 = 0b011 - encodes [0b00, 0b11] ≡ 3P0 + 3P1
  tab[3].sum(tab[2], P1)

  # Step 2. Convert to affine coordinates to benefit from mixed-addition
  lut.batchAffine(tab)

func w2Get(recoding: Recoded,
          digitIdx: int): uint8 {.inline.}=
  ## Window Get for window of size 2
  ## 0 <= digitIdx < LengthInDigits
  ## returns digit ∈ {0, 1}

  const
    wBitSize   = 2
    wWordMask  = sizeof(byte) * 8 div 2 - 1 #                            - In the word, shift to the offset to read/write
    wDigitMask = 1 shl wBitSize - 1         # Digits take 1-bit          - Once at location, isolate bits to read/write

  const len = Recoded.LengthInDigits
  # assert digitIdx * wBitSize < len, "digitIdx: " & $digitIdx & ", window: " & $wBitsize & ", len: " & $len

  let slot = distinctBase(recoding)[
    (len-1 - 2*digitIdx) shr Shift
  ]
  let recoded = slot shr (wBitSize*(digitIdx and wWordMask)) and wDigitMask
  return recoded

func w2TableIndex(glv: GLV_SAC, bit2: int, isNeg: var SecretBool): SecretWord {.inline.} =
  ## Compose the secret table index from
  ## the windowed of size 2 GLV-SAC representation and the "bit" accessed

  let k0 = glv[0].w2Get(bit2)
  let k1 = glv[1].w2Get(bit2)

  # assert k0 < 4 and k1 < 4

  isNeg = SecretBool(k0 shr 1)
  let parity = (k0 shr 1) xor (k0 and 1)
  result = SecretWord((parity shl 2) or k1)

func computeRecodedLength(bitWidth, window: int): int =
  # Strangely in the paper this doesn't depend
  # "m", the GLV decomposition dimension.
  # lw = ⌈log2 r/w⌉+1 (optionally a second "+1" to handle negative mini scalars)
  let lw = (bitWidth + window - 1) div window + 1
  result = (lw mod window) + lw

func scalarMulGLV_m2w2*[scalBits; EC](
       P0: var EC,
       scalar: BigInt[scalBits]
     ) =
  ## Elliptic Curve Scalar Multiplication
  ##
  ##   P <- [k] P
  ##
  ## This is a scalar multiplication accelerated by an endomorphism
  ## via the GLV (Gallant-lambert-Vanstone) decomposition.
  ##
  ## For 2-dimensional decomposition with window 2
  ##
  ## Requires:
  ## - Cofactor to be cleared
  ## - 0 <= scalar < curve order
  mixin affine
  type ECaff = affine(EC)
  const C = P0.F.C # curve
  static: doAssert: scalBits == C.getCurveOrderBitwidth()

  # 1. Compute endomorphisms
  when P0.G == G1:
    var P1 = P0
    P1.x *= C.getCubicRootOfUnity_mod_p()
  else:
    var P1 {.noInit.}: EC
    P1.frobenius_psi(P0, 2)

  # 2. Decompose scalar into mini-scalars
  const L = computeRecodedLength(C.getCurveOrderBitwidth(), 2)
  var miniScalars {.noInit.}: array[2, BigInt[L]]
  var negatePoints {.noInit.}: array[2, SecretBool]
  miniScalars.decomposeEndo(negatePoints, scalar, P0.F)

  # 3. Handle negative mini-scalars
  #    Either negate the associated base and the scalar (in the `endomorphisms` array)
  #    Or use Algorithm 3 from Faz et al which can encode the sign
  #    in the GLV representation at the low low price of 1 bit
  block:
    P0.cneg(negatePoints[0])
    P1.cneg(negatePoints[1])

  # 4. Precompute lookup table
  var lut {.noInit.}: array[8, ECaff]
  buildLookupTable_m2w2(P0, P1, lut)

  # 5. Recode the miniscalars
  #    we need the base miniscalar (that encodes the sign)
  #    to be odd, and this in constant-time to protect the secret least-significant bit.
  let k0isOdd = miniScalars[0].isOdd()
  discard miniScalars[0].cadd(One, not k0isOdd)

  var recoded: GLV_SAC[2, L] # zero-init required
  recoded.nDimMultiScalarRecoding(miniScalars)

  # 6. Proceed to GLV accelerated scalar multiplication
  var Q {.noInit.}: EC
  var tmp {.noInit.}: ECaff
  var isNeg: SecretBool

  tmp.secretLookup(lut, recoded.w2TableIndex((L div 2) - 1, isNeg))
  Q.fromAffine(tmp)

  for i in countdown((L div 2) - 2, 0):
    Q.double()
    Q.double()
    tmp.secretLookup(lut, recoded.w2TableIndex(i, isNeg))
    tmp.cneg(isNeg)
    Q += tmp

  # Now we need to correct if the sign miniscalar was not odd
  P0.diff(Q, P0)
  P0.ccopy(Q, k0isOdd)

# Sanity checks
# ----------------------------------------------------------------
# See page 7 of
#
# - Efficient and Secure Algorithms for GLV-Based Scalar
#   Multiplication and their Implementation on GLV-GLS
#   Curves (Extended Version)
#   Armando Faz-Hernández, Patrick Longa, Ana H. Sánchez, 2013
#   https://eprint.iacr.org/2013/158.pdf

when isMainModule:
  import ../io/io_bigints

  proc toString(glvSac: GLV_SAC): string =
    for j in 0 ..< glvSac.M:
      result.add "k" & $j & ": ["
      for i in countdown(glvSac.LengthInDigits-1, 0):
        result.add " " & (block:
          case glvSac[j][i]
          of 0: "0"
          of 1: "1"
          else:
            raise newException(ValueError, "Unexpected encoded value: " & $glvSac[j][i])
        )
      result.add " ]\n"


  iterator bits(u: SomeInteger): tuple[bitIndex: int32, bitValue: uint8] =
    ## bit iterator, starts from the least significant bit
    var u = u
    var idx = 0'i32
    while u != 0:
      yield (idx, uint8(u and 1))
      u = u shr 1
      inc idx

  func buildLookupTable_naive[M: static int](
         P: string,
         endomorphisms: array[M-1, string],
         lut: var array[1 shl (M-1), string],
       ) =
    ## Checking the LUT by building strings of endomorphisms additions
    ## This naively translates the lookup table algorithm
    ## Compute P[u] = P0 + u0 P1 +...+ um−2 Pm−1 for all 0≤u<2m−1, where
    ## u= (um−2,...,u0)_2.
    ## The number of additions done per entries is equal to the
    ## iteration variable `u` Hamming Weight
    for u in 0 ..< 1 shl (M-1):
      lut[u] = P
    for u in 0 ..< 1 shl (M-1):
      for idx, bit in bits(u):
        if bit == 1:
          lut[u] &= " + " & endomorphisms[idx]

  func buildLookupTable_reuse[M: static int](
         P: string,
         endomorphisms: array[M-1, string],
         lut: var array[1 shl (M-1), string],
       ) =
    ## Checking the LUT by building strings of endomorphisms additions
    ## This reuses previous table entries so that only one addition is done
    ## per new entries
    lut[0] = P
    for u in 1'u32 ..< 1 shl (M-1):
      let msb = u.log2_vartime() # No undefined, u != 0
      lut[u] = lut[u.clearBit(msb)] & " + " & endomorphisms[msb]

  proc main_lut() =
    const M = 4              # GLS-4 decomposition
    const miniBitwidth = 4   # Bitwidth of the miniscalars resulting from scalar decomposition

    var k: MultiScalar[M, miniBitwidth]
    var kRecoded: GLV_SAC[M, miniBitwidth]

    k[0].fromUint(11)
    k[1].fromUint(6)
    k[2].fromuint(14)
    k[3].fromUint(3)

    kRecoded.nDimMultiScalarRecoding(k)

    echo "Recoded bytesize: ", sizeof(kRecoded)
    echo kRecoded.toString()

    var lut: array[1 shl (M-1), string]
    let
      P = "P0"
      endomorphisms = ["P1", "P2", "P3"]

    buildLookupTable_naive(P, endomorphisms, lut)
    echo lut
    doAssert lut[0] == "P0"
    doAssert lut[1] == "P0 + P1"
    doAssert lut[2] == "P0 + P2"
    doAssert lut[3] == "P0 + P1 + P2"
    doAssert lut[4] == "P0 + P3"
    doAssert lut[5] == "P0 + P1 + P3"
    doAssert lut[6] == "P0 + P2 + P3"
    doAssert lut[7] == "P0 + P1 + P2 + P3"

    var lut_reuse: array[1 shl (M-1), string]
    buildLookupTable_reuse(P, endomorphisms, lut_reuse)
    echo lut_reuse
    doAssert lut == lut_reuse

  main_lut()
  echo "---------------------------------------------"

  proc main_decomp() =
    const M = 2
    const scalBits = BN254_Snarks.getCurveOrderBitwidth()
    const miniBits = (scalBits+M-1) div M
    const L = miniBits + 1

    block:
      let scalar = BigInt[scalBits].fromHex(
        "0x24a0b87203c7a8def0018c95d7fab106373aebf920265c696f0ae08f8229b3f3"
      )

      var decomp: MultiScalar[M, L]
      decomp.decomposeEndo(scalar, Fp[BN254_Snarks])

      doAssert: bool(decomp[0] == BigInt[L].fromHex"14928105460c820ccc9a25d0d953dbfe")
      doAssert: bool(decomp[1] == BigInt[L].fromHex"13a2f911eb48a578844b901de6f41660")

    block:
      let scalar = BigInt[scalBits].fromHex(
        "24554fa6d0c06f6dc51c551dea8b058cd737fc8d83f7692fcebdd1842b3092c4"
      )

      var decomp: MultiScalar[M, L]
      decomp.decomposeEndo(scalar, Fp[BN254_Snarks])

      doAssert: bool(decomp[0] == BigInt[L].fromHex"28cf7429c3ff8f7e82fc419e90cc3a2")
      doAssert: bool(decomp[1] == BigInt[L].fromHex"457efc201bdb3d2e6087df36430a6db6")

    block:
      let scalar = BigInt[scalBits].fromHex(
        "288c20b297b9808f4e56aeb70eabf269e75d055567ff4e05fe5fb709881e6717"
      )

      var decomp: MultiScalar[M, L]
      decomp.decomposeEndo(scalar, Fp[BN254_Snarks])

      doAssert: bool(decomp[0] == BigInt[L].fromHex"4da8c411566c77e00c902eb542aaa66b")
      doAssert: bool(decomp[1] == BigInt[L].fromHex"5aa8f2f15afc3217f06677702bd4e41a")


  main_decomp()
  echo "---------------------------------------------"

  # This tests the multiplication against the Table 1
  # of the paper

  # Coef       Decimal    Binary        GLV-SAC recoded
  # | k0 |     | 11 |   | 0 1 0 1 1 |   | 1 -1 1 -1 1 |
  # | k1 |  =  |  6 | = | 0 0 1 1 0 | = | 1 -1 0 -1 0 |
  # | k2 |     | 14 |   | 0 1 1 1 0 |   | 1  0 0 -1 0 |
  # | k3 |     |  3 |   | 0 0 0 1 1 |   | 0  0 1 -1 1 |

  #   i                |         3               2             1             0
  # -------------------+----------------------------------------------------------------------
  #  2Q                |   2P0+2P1+2P2    2P0+2P1+4P2    6P0+4P1+8P2+2P3  10P0+6P1+14P2+2P3
  # Q + sign_i T[ki]   |    P0+P1+2P2   3P0+2P1+4P2+P3   5P0+3P1+7P2+P3   11P0+6P1+14P2+3P3

  type Endo = enum
    P0
    P1
    P2
    P3

  func buildLookupTable_reuse[M: static int](
         P: Endo,
         endomorphisms: array[M-1, Endo],
         lut: var array[1 shl (M-1), set[Endo]],
       ) =
    ## Checking the LUT by building strings of endomorphisms additions
    ## This reuses previous table entries so that only one addition is done
    ## per new entries
    lut[0].incl P
    for u in 1'u32 ..< 1 shl (M-1):
      let msb = u.log2_vartime() # No undefined, u != 0
      lut[u] = lut[u.clearBit(msb)] + {endomorphisms[msb]}


  proc mainFullMul() =
    const M = 4                # GLS-4 decomposition
    const miniBitwidth = 4     # Bitwidth of the miniscalars resulting from scalar decomposition
    const L = miniBitwidth + 1 # Bitwidth of the recoded scalars

    var k: MultiScalar[M, L]
    var kRecoded: GLV_SAC[M, L]

    k[0].fromUint(11)
    k[1].fromUint(6)
    k[2].fromuint(14)
    k[3].fromUint(3)

    kRecoded.nDimMultiScalarRecoding(k)

    echo kRecoded.toString()

    var lut: array[1 shl (M-1), set[Endo]]
    let
      P = P0
      endomorphisms = [P1, P2, P3]

    buildLookupTable_reuse(P, endomorphisms, lut)
    echo lut

    var Q: array[Endo, int]

    # Multiplication
    assert bool k[0].isOdd()
    # Q = sign_l-1 P[K_l-1]
    let idx = kRecoded.tableIndex(L-1)
    for p in lut[int(idx)]:
      Q[p] = if kRecoded[0][L-1] == 0: 1 else: -1
    # Loop
    for i in countdown(L-2, 0):
      # Q = 2Q
      for val in Q.mitems: val *= 2
      echo "2Q:                    ", Q
      # Q = Q + sign_l-1 P[K_l-1]
      let idx = kRecoded.tableIndex(i)
      for p in lut[int(idx)]:
        Q[p] += (if kRecoded[0][i] == 0: 1 else: -1)
      echo "Q + sign_l-1 P[K_l-1]: ", Q

    echo Q

  mainFullMul()
  echo "---------------------------------------------"

  func buildLookupTable_m2w2(
        lut: var array[8, array[2, int]],
      ) =
    ## Build a lookup table for GLV with 2-dimensional decomposition
    ## and window of size 2

    # with [k0, k1] the mini-scalars with digits of size 2-bit
    #
    # 0 = 0b000 - encodes [0b01, 0b00] ≡ P0
    lut[0] = [1, 0]
    # 1 = 0b001 - encodes [0b01, 0b01] ≡ P0 - P1
    lut[1] = [1, -1]
    # 3 = 0b011 - encodes [0b01, 0b11] ≡ P0 + P1
    lut[3] = [1, 1]
    # 2 = 0b010 - encodes [0b01, 0b10] ≡ P0 + 2P1
    lut[2] = [1, 2]

    # 4 = 0b100 - encodes [0b00, 0b00] ≡ 3P0
    lut[4] = [3, 0]
    # 5 = 0b101 - encodes [0b00, 0b01] ≡ 3P0 + P1
    lut[5] = [3, 1]
    # 6 = 0b110 - encodes [0b00, 0b10] ≡ 3P0 + 2P1
    lut[6] = [3, 2]
    # 7 = 0b111 - encodes [0b00, 0b11] ≡ 3P0 + 3P1
    lut[7] = [3, 3]

  proc mainFullMulWindowed() =
    const M = 2                # GLS-2 decomposition
    const miniBitwidth = 8     # Bitwidth of the miniscalars resulting from scalar decomposition
    const W = 2                # Window
    const L = computeRecodedLength(miniBitwidth, W)

    var k: MultiScalar[M, L]
    var kRecoded: GLV_SAC[M, L]

    k[0].fromUint(11)
    k[1].fromUint(14)

    kRecoded.nDimMultiScalarRecoding(k)

    echo "Recoded bytesize: ", sizeof(kRecoded)
    echo kRecoded.toString()

    var lut: array[8, array[range[P0..P1], int]]
    buildLookupTable_m2w2(lut)
    echo lut

    # Assumes k[0] is odd to simplify test
    # and having to conditional substract at the end
    assert bool k[0].isOdd()

    var Q: array[Endo, int]
    var isNeg: SecretBool

    let idx = kRecoded.w2TableIndex((L div 2)-1, isNeg)
    for p, coef in lut[int(idx)]:
      # Unneeeded by construction
      # let sign = if isNeg: -1 else: 1
      Q[p] = coef

    # Loop
    for i in countdown((L div 2)-2, 0):
      # Q = 4Q
      for val in Q.mitems: val *= 4
      echo "4Q:                    ", Q
      # Q = Q + sign_l-1 P[K_l-1]
      let idx = kRecoded.w2TableIndex(i, isNeg)
      for p, coef in lut[int(idx)]:
        let sign = (if bool isNeg: -1 else: 1)
        Q[p] += sign * coef
      echo "Q + sign_l-1 P[K_l-1]: ", Q

    echo Q

  mainFullMulWindowed()
