module TTImp.Elab

import Core.Context
import Core.Core
import Core.Env
import Core.LinearCheck
import Core.Metadata
import Core.Normalise
import Core.Transform
import Core.UnifyState
import Core.Unify

import TTImp.Elab.Check
import TTImp.Elab.Delayed
import TTImp.Elab.Term
import TTImp.TTImp
import TTImp.Unelab

import Data.IntMap
import Data.NameMap

findPLetRenames : Term vars -> List (Name, (RigCount, Name))
findPLetRenames (Bind fc n (PLet c (Local {name = x@(MN _ _)} _ _ _ p) ty) sc)
    = (x, (c, n)) :: findPLetRenames sc
findPLetRenames (Bind fc n _ sc) = findPLetRenames sc
findPLetRenames tm = []

doPLetRenames : List (Name, (RigCount, Name)) ->
                List Name -> Term vars -> Term vars
doPLetRenames ns drops (Bind fc n b@(PLet _ _ _) sc)
    = if n `elem` drops
         then subst (Erased fc False) (doPLetRenames ns drops sc)
         else Bind fc n b (doPLetRenames ns drops sc)
doPLetRenames ns drops (Bind fc n b sc)
    = case lookup n ns of
           Just (c, n') =>
              Bind fc n' (setMultiplicity b (max c (multiplicity b)))
                   (doPLetRenames ns (n' :: drops) (renameTop n' sc))
           Nothing => Bind fc n b (doPLetRenames ns drops sc)
doPLetRenames ns drops sc = sc

getRigNeeded : ElabMode -> RigCount
getRigNeeded InType = Rig0 -- unrestricted usage in types
getRigNeeded (InLHS Rig0) = Rig0
getRigNeeded _ = Rig1

-- Make sure the types of holes have the references to solved holes normalised
-- away (since solved holes don't get written to .tti)
export
normaliseHoleTypes : {auto c : Ref Ctxt Defs} ->
                     {auto u : Ref UST UState} ->
                     Core ()
normaliseHoleTypes
    = do ust <- get UST
         let hs = keys (holes ust)
         defs <- get Ctxt
         traverse (normaliseH defs) hs
         pure ()
  where
    updateType : Defs -> Int -> GlobalDef -> Core ()
    updateType defs i def
        = do ty' <- normaliseHoles defs [] (type def)
             addDef (Resolved i) (record { type = ty' } def)
             pure ()

    normaliseH : Defs -> Int -> Core ()
    normaliseH defs i
        = case !(lookupCtxtExact (Resolved i) (gamma defs)) of
               Just gdef =>
                  case definition gdef of
                       Hole _ _ => updateType defs i gdef
                       _ => pure ()
               Nothing => pure ()

export
addHoleToSave : {auto c : Ref Ctxt Defs} ->
                Name -> Core ()
addHoleToSave n
    = do defs <- get Ctxt
         Just ty <- lookupTyExact n (gamma defs)
              | Nothing => pure ()
         let ms = keys (getMetas ty)
         addToSave n
         traverse_ addToSave ms

export
elabTermSub : {vars : _} ->
              {auto c : Ref Ctxt Defs} ->
              {auto m : Ref MD Metadata} ->
              {auto u : Ref UST UState} ->
              Int -> ElabMode -> List ElabOpt ->
              NestedNames vars -> Env Term vars ->
              Env Term inner -> SubVars inner vars ->
              RawImp -> Maybe (Glued vars) ->
              Core (Term vars, Glued vars)
elabTermSub {vars} defining mode opts nest env env' sub tm ty
    = do let incase = elem InCase opts
         let holesokay = elem HolesOkay opts

         -- Record the current hole state; we only check the list of current
         -- holes is completely solved so this needs to be accurate.
         oldhs <- if not incase
                     then saveHoles
                     else pure empty
         ust <- get UST
         let olddelayed = delayedElab ust
         put UST (record { delayedElab = [] } ust)
         constart <- getNextEntry

         defs <- get Ctxt
         e <- newRef EST (initEStateSub defining env' sub)
         let rigc = getRigNeeded mode

         (chktm, chkty) <- check {e} rigc (initElabInfo mode) nest env tm ty
         -- Final retry of constraints and delayed elaborations
         -- - Solve any constraints, then retry any delayed elaborations
         -- - Finally, last attempts at solving constraints, but this
         --   is most likely just to be able to display helpful errors
         let solvemode = case mode of
                              InLHS _ => inLHS
                              _ => inTermP False
         solveConstraints solvemode Normal
         logTerm 5 "Looking for delayed in " chktm
         ust <- get UST
         catch (retryDelayed (reverse (delayedElab ust)))
               (\err =>
                  do ust <- get UST
                     put UST (record { delayedElab = olddelayed } ust)
                     throw err)
         ust <- get UST
         put UST (record { delayedElab = olddelayed } ust)
         solveConstraintsAfter constart solvemode MatchArgs

         -- As long as we're not in a case block, finish off constraint solving
         when (not incase) $
           -- resolve any default hints
           do log 5 "Resolving default hints"
              solveConstraintsAfter constart solvemode Defaults
              -- perhaps resolving defaults helps...
              -- otherwise, this last go is most likely just to give us more
              -- helpful errors.
              solveConstraintsAfter constart solvemode LastChance

         dumpConstraints 4 False
         defs <- get Ctxt
         chktm <- normaliseArgHoles defs env chktm

         -- Linearity and hole checking.
         -- on the LHS, all holes need to have been solved
         chktm <- the (Core (Term vars)) $ case mode of
              InLHS _ => do when (not incase) $ checkUserHoles True
                            pure chktm
              -- elsewhere, all unification problems must be
              -- solved, though we defer that if it's a case block since we
              -- might learn a bit more later.
              _ => if (not incase)
                      then do checkNoGuards
                              linearCheck (getFC tm) rigc False env chktm
                          -- Linearity checking looks in case blocks, so no
                          -- need to check here.
                      else pure chktm
         normaliseHoleTypes
         -- Put the current hole state back to what it was (minus anything
         -- which has been solved in the meantime)
         when (not incase) $
           do hs <- getHoles
              restoreHoles (addHoles empty hs (toList oldhs))

         -- Make a note to save all the user holes and the things they
         -- reference
         est <- get EST
         traverse_ addHoleToSave (keys (saveHoles est))

         -- On the LHS, finish by tidying up the plets (changing things that
         -- were of the form x@_, where the _ is inferred to be a variable,
         -- to just x)
         case mode of
              InLHS _ =>
                 do let vs = findPLetRenames chktm
                    let ret = doPLetRenames vs [] chktm
                    pure (ret, gnf env (doPLetRenames vs [] !(getTerm chkty)))
              _ => do dumpConstraints 2 False
                      pure (chktm, chkty)
  where
    addHoles : (acc : IntMap (FC, Name)) ->
               (allHoles : IntMap (FC, Name)) ->
               List (Int, (FC, Name)) ->
               IntMap (FC, Name)
    addHoles acc allhs [] = acc
    addHoles acc allhs ((n, x) :: hs)
        = case lookup n allhs of
               Nothing => addHoles acc allhs hs
               Just _ => addHoles (insert n x acc) allhs hs

export
elabTerm : {vars : _} ->
           {auto c : Ref Ctxt Defs} ->
           {auto m : Ref MD Metadata} ->
           {auto u : Ref UST UState} ->
           Int -> ElabMode -> List ElabOpt ->
           NestedNames vars -> Env Term vars ->
           RawImp -> Maybe (Glued vars) ->
           Core (Term vars, Glued vars)
elabTerm defining mode opts nest env tm ty
    = elabTermSub defining mode opts nest env env SubRefl tm ty

export
checkTermSub : {vars : _} ->
               {auto c : Ref Ctxt Defs} ->
               {auto m : Ref MD Metadata} ->
               {auto u : Ref UST UState} ->
               Int -> ElabMode -> List ElabOpt ->
               NestedNames vars -> Env Term vars ->
               Env Term inner -> SubVars inner vars ->
               RawImp -> Glued vars ->
               Core (Term vars)
checkTermSub defining mode opts nest env env' sub tm ty
    = do defs <- the (Core Defs) $ case mode of
                      InType => branch -- might need to backtrack if there's
                                       -- a case in the type
                      _ => get Ctxt
         ust <- get UST
         mv <- get MD
         res <-
            catch {t = Error}
                  (elabTermSub defining mode opts nest
                               env env' sub tm (Just ty))
                  (\err => case err of
                              TryWithImplicits loc benv ns
                                 => do put Ctxt defs
                                       put UST ust
                                       put MD mv
                                       tm' <- bindImps loc benv ns tm
                                       elabTermSub defining mode opts nest
                                                   env env' sub
                                                   tm' (Just ty)
                              _ => throw err)
         pure (fst res)
  where
    bindImps : FC -> Env Term vs -> List (Name, Term vs) -> RawImp ->
               Core RawImp
    bindImps loc env [] ty = pure ty
    bindImps loc env ((n, ty) :: ntys) sc
        = pure $ IPi loc Rig0 Implicit (Just n)
                     !(unelabNoSugar env ty) !(bindImps loc env ntys sc)

export
checkTerm : {vars : _} ->
            {auto c : Ref Ctxt Defs} ->
            {auto m : Ref MD Metadata} ->
            {auto u : Ref UST UState} ->
            Int -> ElabMode -> List ElabOpt ->
            NestedNames vars -> Env Term vars ->
            RawImp -> Glued vars ->
            Core (Term vars)
checkTerm defining mode opts nest env tm ty
    = checkTermSub defining mode opts nest env env SubRefl tm ty
