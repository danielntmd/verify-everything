use core::fmt::Display;
use core::traits::Destruct;
use core::clone::Clone;
use core::traits::Into;
use core::debug::{PrintTrait, print_byte_array_as_string};
use core::array::ArrayTrait;
use core::cmp::max;

use plonk_verifier::traits::FieldMulShortcuts;
use plonk_verifier::plonk::transcript::Keccak256Transcript;
use plonk_verifier::curve::groups::{g1, g2, AffineG1, AffineG2};
use plonk_verifier::curve::groups::ECOperations;
use plonk_verifier::fields::{fq, Fq, fq2, Fq2, FqOps, FqUtils};
use plonk_verifier::curve::constants::{ORDER};
use plonk_verifier::plonk::types::{PlonkProof, PlonkVerificationKey, PlonkChallenge};
use plonk_verifier::plonk::transcript::{Transcript, TranscriptElement};

#[generate_trait]
impl PlonkVerifier of PVerifier {
    fn verify(
        verification_key: PlonkVerificationKey, proof: PlonkProof, publicSignals: Array<u256>
    ) -> bool {
        let mut result = true;
        result = result
            && Self::is_on_curve(proof.A)
            && Self::is_on_curve(proof.B)
            && Self::is_on_curve(proof.C)
            && Self::is_on_curve(proof.Z)
            && Self::is_on_curve(proof.T1)
            && Self::is_on_curve(proof.T2)
            && Self::is_on_curve(proof.T3)
            && Self::is_on_curve(proof.Wxi)
            && Self::is_on_curve(proof.Wxiw);

        result = result
            && Self::is_in_field(proof.eval_a)
            && Self::is_in_field(proof.eval_b)
            && Self::is_in_field(proof.eval_c)
            && Self::is_in_field(proof.eval_s1)
            && Self::is_in_field(proof.eval_s2)
            && Self::is_in_field(proof.eval_zw);

        result = result
            && Self::check_public_inputs_length(
                verification_key.nPublic, publicSignals.len().into()
            );
        let mut _challenges: PlonkChallenge = Self::compute_challenges(
            verification_key, proof, publicSignals
        );

        result
    }

    // step 1: check if the points are on the bn254 curve
    fn is_on_curve(pt: AffineG1) -> bool {
        // bn254 curve equation: y^2 = x^3 + 3
        let x_sqr = pt.x.sqr();
        let x_cubed = x_sqr.mul(pt.x);
        let lhs = x_cubed.add(fq(3));
        let rhs = pt.y.sqr();

        rhs == lhs
    }

    // step 2: check if the field element is in the field
    fn is_in_field(num: Fq) -> bool {
        // bn254 curve field:
        // 21888242871839275222246405745257275088548364400416034343698204186575808495617
        let field_p = fq(ORDER);

        num.c0 < field_p.c0
    }

    //step 3: check proof public inputs match the verification key
    fn check_public_inputs_length(len_a: u256, len_b: u256) -> bool {
        len_a == len_b
    }

    // step 4: compute challenge
    fn compute_challenges(
        verification_key: PlonkVerificationKey, proof: PlonkProof, publicSignals: Array<u256>
    ) -> PlonkChallenge {
        let mut challenges = PlonkChallenge {
            beta: fq(0),
            gamma: fq(0),
            alpha: fq(0),
            xi: fq(0),
            xin: fq(0),
            zh: fq(0),
            v: array![],
            u: fq(0)
        };

        // Challenge round 2: beta and gamma
        let mut beta_transcript = Transcript::new();
        beta_transcript.add_pol_commitment(verification_key.Qm);
        let c = beta_transcript.data.at(0);
        match c {
            TranscriptElement::Polynomial(_pt) => { // println!("ts x: {:?}", pt.x.c0.clone());
            // println!("ts y: {:?}", pt.y.c0.clone());
            },
            TranscriptElement::Scalar(s) => { println!("ts x: {:?}", s); },
        };

        beta_transcript.add_pol_commitment(verification_key.Ql);
        beta_transcript.add_pol_commitment(verification_key.Qr);
        beta_transcript.add_pol_commitment(verification_key.Qo);
        beta_transcript.add_pol_commitment(verification_key.Qc);
        beta_transcript.add_pol_commitment(verification_key.S1);
        beta_transcript.add_pol_commitment(verification_key.S2);
        beta_transcript.add_pol_commitment(verification_key.S3);

        let mut i = 0;
        while i < publicSignals.len() {
            beta_transcript.add_scalar(fq(publicSignals.at(i).clone()));
            i += 1;
        };
        beta_transcript.add_pol_commitment(proof.A);
        beta_transcript.add_pol_commitment(proof.B);
        beta_transcript.add_pol_commitment(proof.C);

        challenges.beta = beta_transcript.get_challenge();
        let mut challenges_beta = challenges.beta.c0.clone();
        println!("challenges beta: {:?}", challenges_beta);

        let mut gamma_transcript = Transcript::new();
        gamma_transcript.add_scalar(challenges.beta);
        challenges.gamma = gamma_transcript.get_challenge();

        // Challenge round 3: alpha
        let mut alpha_transcript = Transcript::new();
        alpha_transcript.add_scalar(challenges.beta);
        alpha_transcript.add_scalar(challenges.gamma);
        alpha_transcript.add_pol_commitment(proof.Z);
        challenges.alpha = alpha_transcript.get_challenge();

        // Challenge round 4: xi
        let mut xi_transcript = Transcript::new();
        xi_transcript.add_scalar(challenges.alpha);
        xi_transcript.add_pol_commitment(proof.T1);
        xi_transcript.add_pol_commitment(proof.T2);
        xi_transcript.add_pol_commitment(proof.T3);
        challenges.xi = xi_transcript.get_challenge();

        // // Challenge round 5: v
        let mut v_transcript = Transcript::new();
        v_transcript.add_scalar(challenges.xi);
        v_transcript.add_scalar(proof.eval_a);
        v_transcript.add_scalar(proof.eval_b);
        v_transcript.add_scalar(proof.eval_c);
        v_transcript.add_scalar(proof.eval_s1);
        v_transcript.add_scalar(proof.eval_s2);
        v_transcript.add_scalar(proof.eval_zw);
        challenges.v.append(fq(0));
        challenges.v.append(v_transcript.get_challenge());

        let mut i = 2;
        loop {
            if i < 6 {
                let mut to_mul = challenges.v.at(1).clone();
                to_mul = to_mul.mul(challenges.v.at(i - 1).clone());
                challenges.v.append(to_mul);
            } else {
                break;
            }

            i += 1;
        };

        // Challenge: u
        let mut u_transcript = Transcript::new();
        u_transcript.add_pol_commitment(proof.Wxi);
        u_transcript.add_pol_commitment(proof.Wxiw);
        challenges.u = u_transcript.get_challenge();

        challenges
    }
    // step 6: calculate the lagrange evaluations
    fn calculate_lagrange_evaluations(
        verification_key: PlonkVerificationKey, mut challenges: PlonkChallenge
    ) -> Array<Fq> {
        let mut xin = challenges.xi;
        let mut domain_size = 1;

        let mut i = 0;
        while i < verification_key.power {
            xin = xin.sqr();
            domain_size *= 2;
            i += 1;
        };
        challenges.xin = xin;
        challenges.zh = xin.sub(fq(1));

        let mut lagrange_evaluations = array![];
        lagrange_evaluations.append(fq(0));
        let n: Fq = fq(domain_size);
        let mut w: Fq = FqUtils::one();

        let mut j = 1;
        while j <= max(1, verification_key.nPublic) {
            let mut xi_sub_w = challenges.xi.sub(w);
            let mut xi_mul_n = xi_sub_w.mul(n);
            let mut w_mul_zh = w.mul(challenges.zh);
            let mut div = w_mul_zh.div(xi_mul_n);
            lagrange_evaluations.append(div);

            // roots of unity check, need to fix
            w = w.mul(fq(verification_key.power));

            j += 1;
        };

        lagrange_evaluations
    }
}
