
"""
    runabc(ABCsetup::ABCtype, targetdata; progress = false)

Run ABC with ABCsetup defining the algotrithm and inputs to algorithm, targetdata is the data we wish to fit the model to and will be used as an input for the simulation function defined in ABCsetup. If progress is set to `true` a progress meter will be shown.
"""
function runabc(ABCsetup::ABCRejection, targetdata; progress = false, verbose = false)

  #initalize array of particles
  particles = Array{ParticleRejection}(ABCsetup.nparticles)
  particlesall = Array{ParticleRejection}(ABCsetup.maxiterations)

  i = 1 #set particle indicator to 1
  its = 0 #keep track of number of iterations
  distvec = zeros(Float64, ABCsetup.nparticles) #store distances in an array

  if progress == true
    p = Progress(ABCsetup.nparticles, 1, "Running ABC rejection algorithm...", 30)
  end

  while (i < (ABCsetup.nparticles + 1)) & (its < ABCsetup.maxiterations)

    its += 1
    #get new proposal parameters
    newparams = getproposal(ABCsetup.prior, ABCsetup.nparams)
    #simulate with new parameters
    dist, out = ABCsetup.simfunc(newparams, ABCsetup.constants, targetdata)
    #keep track of all particles incase we don't reach nparticles with dist < ϵ
    particlesall[its] = ParticleRejection(newparams, dist, out)

    #if simulated data is less than target tolerance accept particle
    if dist < ABCsetup.ϵ
      particles[i] = ParticleRejection(newparams, dist, out)
      distvec[i] = dist
      i +=1
      if progress == true
        next!(p)
      end
    end
  end

  if i < ABCsetup.nparticles
    warn("Only accepted $(i-1) particles with ϵ < $(ABCsetup.ϵ). \n\tDecrease ϵ or increase maxiterations if you require this. \n\t Resorting to taking the $(ABCsetup.nparticles) particles with smallest distance")
    d = map(p -> p.distance, particlesall)
    particles = particlesall[sortperm(d)[1:ABCsetup.nparticles]]
    distvec = map(p -> p.distance, particles)
  end

  out = ABCrejectionresults(particles, its, ABCsetup, distvec)
  return out
end


function runabc(ABCsetup::ABCRejectionModel, targetdata; progress = false, verbose = false)

  ABCsetup.nmodels > 1 || error("Only 1 model specified, use ABCRejection method to estimate parameters for a single model")

  #initalize array of particles
  particles = Array{ParticleRejectionModel}(ABCsetup.Models[1].nparticles)

  i = 1 #set particle indicator to 1
  its = 0 #keep track of number of iterations
  distvec = zeros(Float64, ABCsetup.Models[1].nparticles) #store distances in an array

  if progress == true
    p = Progress(ABCsetup.Models[1].nparticles, 1, "Running ABC rejection algorithm...", 30)
  end

  while (i < (ABCsetup.Models[1].nparticles + 1)) & (its < ABCsetup.Models[1].maxiterations)

    its += 1
    #sample uniformly from models
    model = rand(1:ABCsetup.nmodels)
    #get new proposal parameters
    newparams = getproposal(ABCsetup.Models[model].prior, ABCsetup.Models[model].nparams)
    #simulate with new parameters
    dist, out = ABCsetup.Models[model].simfunc(newparams, ABCsetup.Models[model].constants, targetdata)

    #if simulated data is less than target tolerance accept particle
    if dist < ABCsetup.Models[1].ϵ
      particles[i] = ParticleRejectionModel(newparams, model, dist, out)
      distvec[i] = dist
      i +=1
      if progress == true
        next!(p)
      end
    end
  end

  i > ABCsetup.Models[1].nparticles || error("Only accepted $(i-1) particles with ϵ < $(ABCsetup.Models[1].ϵ). \n\tDecrease ϵ or increase maxiterations ")

  out = ABCrejectionmodelresults(particles, its, ABCsetup, distvec)
  return out
end

function runabc(ABCsetup::ABCSMC, targetdata; verbose = false, progress = false)

  #run first population with parameters sampled from prior
  if verbose == true
    println("##################################################")
    println("Use ABC rejection to get first population")
  end
  ABCrejresults = runabc(ABCRejection(ABCsetup.simfunc, ABCsetup.nparams,
                  ABCsetup.ϵ1, ABCsetup.prior; nparticles = ABCsetup.nparticles,
                  maxiterations = ABCsetup.maxiterations, constants = ABCsetup.constants), targetdata, progress = progress);

  oldparticles, weights = setupSMCparticles(ABCrejresults, ABCsetup)
  ϵ = quantile(ABCrejresults.dist, ABCsetup.α) # set new ϵ to αth quantile
  ϵvec = [ϵ] #store epsilon values
  numsims = [ABCrejresults.numsims] #keep track of number of simualtions
  particles = Array{ParticleSMC}(ABCsetup.nparticles) #define particles array

  if verbose == true
    println("Run ABC SMC \n")
  end

  popnum = 1
  finalpop = false

  if sum(ABCrejresults.dist .< ABCsetup.ϵT) == ABCsetup.nparticles
      warn("Target ϵ reached with ABCRejection algorithm, no need to use ABC SMC algorithm, returning ABCRejection output...")
      return ABCrejresults
  end

  while (ϵ > ABCsetup.ϵT) & (sum(numsims) < ABCsetup.maxiterations)

    i = 1 #set particle indicator to 1
    particles = Array{ParticleSMC}(ABCsetup.nparticles)
    distvec = zeros(Float64, ABCsetup.nparticles)
    its = 1
    if progress == true
      p = Progress(ABCsetup.nparticles, 1, "ABC SMC population $(popnum), new ϵ: $(round(ϵ, 2))...", 30)
    end
    while i < ABCsetup.nparticles + 1

      j = wsample(1:ABCsetup.nparticles, weights)
      particle = oldparticles[j]
      newparticle = perturbparticle(particle)
      priorp = priorprob(newparticle.params, ABCsetup.prior)
      if priorp == 0.0 #return to beginning of loop if prior probability is 0
        continue
      end

      #simulate with new parameters
      dist, out = ABCsetup.simfunc(newparticle.params, ABCsetup.constants, targetdata)

      #if simulated data is less than target tolerance accept particle
      if dist < ϵ
        particles[i] = newparticle
        particles[i].other = out
        particles[i].distance = dist
        distvec[i] = dist
        i += 1
        if progress == true
          next!(p)
        end
      end
      its += 1
    end

    particles, weights = smcweights(particles, oldparticles, ABCsetup.prior)
    particles = getscales(particles, ABCsetup)
    oldparticles = particles

    if finalpop == true
      break
    end

    ϵ = quantile(distvec, ABCsetup.α)

    if ϵ < ABCsetup.ϵT
      ϵ = ABCsetup.ϵT
      push!(ϵvec, ϵ)
      push!(numsims, its)
      popnum = popnum + 1
      finalpop = true
      continue
    end

    push!(ϵvec, ϵ)
    push!(numsims, its)

    if ((( abs(ϵvec[end - 1] - ϵ )) / ϵvec[end - 1]) < ABCsetup.convergence) == true
      if verbose == true
        println("New ϵ is within $(round(ABCsetup.convergence * 100, 2))% of previous population, stop ABC SMC")
      end
      break
    end

    popnum = popnum + 1

    if verbose == true
      println("##################################################")
      show(ABCSMCresults(particles, numsims, ABCsetup, ϵvec))
      println("##################################################\n")
    end
  end

  out = ABCSMCresults(particles, numsims, ABCsetup, ϵvec)
  return out
end

"""
    runabc(ABCsetup::ABCtype, targetdata; progress = false, verbose  = false)

When the SMC algorithms are used, a print out at the end of each population will be made if verbose = true.
"""
function runabc(ABCsetup::ABCSMCModel, targetdata; verbose = false, progress = false)

  ABCsetup.nmodels > 1 || error("Only 1 model specified, use ABCSMC method to estimate parameters for a single model")

  #run first population with parameters sampled from prior
  if verbose == true
    println("##################################################")
    println("Use ABC rejection to get first population")
  end
  ABCrejresults = runabc(ABCRejectionModel(
            map(x -> x.simfunc, ABCsetup.Models),
            map(x -> x.nparams, ABCsetup.Models),
            ABCsetup.Models[1].ϵ1,
            map(x -> x.prior, ABCsetup.Models),
            constants = map(x -> x.constants, ABCsetup.Models),
            nparticles = ABCsetup.Models[1].nparticles,
            maxiterations = ABCsetup.Models[1].maxiterations),
            targetdata);

  oldparticles, weights = setupSMCparticles(ABCrejresults, ABCsetup)
  ϵ = quantile(ABCrejresults.dist, ABCsetup.α) # set new ϵ to αth quantile
  ϵvec = [ϵ] #store epsilon values
  numsims = [ABCrejresults.numsims] #keep track of number of simualtions
  particles = Array{ParticleSMCModel}(ABCsetup.nparticles) #define particles array
  weights, modelprob = getparticleweights(oldparticles, ABCsetup)

  modelprob = ABCrejresults.modelfreq

  if verbose == true
    println("Run ABC SMC \n")
  end

  popnum = 1
  finalpop = false

  if verbose == true
    show(ABCSMCmodelresults(oldparticles, numsims, ABCsetup, ϵvec))
  end

  if sum(ABCrejresults.dist .< ABCsetup.ϵT) == ABCsetup.nparticles
      warn("Target ϵ reached with ABCRejection algorithm, no need to use ABC SMC algorithm, returning ABCRejection output...")
      return ABCrejresults
  end

  while (ϵ >= ABCsetup.ϵT) & (sum(numsims) <= ABCsetup.maxiterations)

    i = 1 #set particle indicator to 1
    particles = Array{ParticleSMCModel}(ABCsetup.nparticles)
    distvec = zeros(Float64, ABCsetup.nparticles)
    its = 1

    if progress == true
      p = Progress(ABCsetup.nparticles, 1, "ABC SMC population $(popnum), new ϵ: $(round(ϵ, 2))...", 30)
    end
    while i < ABCsetup.nparticles + 1

      #draw model from previous model probabilities
      mstar = wsample(1:ABCsetup.nmodels, modelprob)
      #perturb model
      mdoublestar = perturbmodel(ABCsetup, mstar, modelprob)
      # sample particle with correct model
      j = wsample(1:ABCsetup.nparticles, weights[mdoublestar, :])
      particletemp = oldparticles[j]

      #perturb particle
      newparticle = perturbparticle(particletemp)
      #calculate priorprob
      priorp = priorprob(newparticle.params, ABCsetup.Models[mdoublestar].prior)

      if priorp == 0.0 #return to beginning of loop if prior probability is 0
        continue
      end

      #simulate with new parameters
      dist, out = ABCsetup.Models[mdoublestar].simfunc(newparticle.params, ABCsetup.Models[mdoublestar].constants, targetdata)

      #if simulated data is less than target tolerance accept particle
      if dist < ϵ
        particles[i] = newparticle
        particles[i].other = out
        particles[i].distance = dist
        distvec[i] = dist
        i += 1
        if progress == true
          next!(p)
        end
      end

      its += 1
    end

    particles, weights = smcweightsmodel(particles, oldparticles, ABCsetup, modelprob)
    weights, modelprob = getparticleweights(particles, ABCsetup)
    particles = getscales(particles, ABCsetup)
    oldparticles = deepcopy(particles)

    if finalpop == true
      break
    end

    ϵ = quantile(distvec, ABCsetup.α)

    if ϵ < ABCsetup.ϵT
      ϵ = ABCsetup.ϵT
      push!(ϵvec, ϵ)
      push!(numsims, its)
      popnum = popnum + 1
      finalpop = true
      continue
    end

    push!(ϵvec, ϵ)
    push!(numsims, its)

    if verbose == true
      println("##################################################")
      show(ABCSMCmodelresults(particles, numsims, ABCsetup, ϵvec))
      println("##################################################\n")
    end

    if ((( abs(ϵvec[end - 1] - ϵ )) / ϵvec[end - 1]) < ABCsetup.convergence) == true
      println("New ϵ is within $(round(ABCsetup.convergence * 100, 2))% of previous population, stop ABC SMC")
      break
    end

    popnum = popnum + 1
  end

  out = ABCSMCmodelresults(particles, numsims, ABCsetup, ϵvec)
  return out
end



function runabcCancer(ABCsetup::ABCRejectionModel, targetdata; progress = false)

  ABCsetup.nmodels > 1 || error("Only 1 model specified, use ABCRejection method to estimate parameters for a single model")

  #initalize array of particles
  particles = Array{ParticleRejectionModel}(ABCsetup.Models[1].nparticles)

  i = 1 #set particle indicator to 1
  its = 0 #keep track of number of iterations
  distvec = zeros(Float64, ABCsetup.Models[1].nparticles) #store distances in an array

  if progress == true
    p = Progress(ABCsetup.Models[1].nparticles, 1, "Running ABC rejection algorithm...", 30)
  end

  dist, out, newparams = 0.0,0.0,0.0

  while (i < (ABCsetup.Models[1].nparticles + 1)) & (its < ABCsetup.Models[1].maxiterations)

    its += 1
    #sample uniformly from models
    model = rand(1:ABCsetup.nmodels)
    correctmodel = false
    while correctmodel == false
      #get new proposal parameters
      newparams = getproposal(ABCsetup.Models[model].prior, ABCsetup.Models[model].nparams)
      #simulate with new parameters
      dist, out, cm = ABCsetup.Models[model].simfunc(newparams, ABCsetup.Models[model].constants, targetdata)
      correctmodel = cm
    end

    #if simulated data is less than target tolerance accept particle
    if dist < ABCsetup.Models[1].ϵ
      particles[i] = ParticleRejectionModel(newparams, model, dist, out)
      distvec[i] = dist
      i +=1
      if progress == true
        next!(p)
      end
    end
  end

  i > ABCsetup.Models[1].nparticles || error("Only accepted $(i-1) particles with ϵ < $(ABCsetup.Models[1].ϵ). \n\tDecrease ϵ or increase maxiterations ")

  out = ABCrejectionmodelresults(particles, its, ABCsetup, distvec)
  return out
end

function runabcCancer(ABCsetup::ABCSMCModel, targetdata; verbose = false, progress = false)

  ABCsetup.nmodels > 1 || error("Only 1 model specified, use ABCSMC method to estimate parameters for a single model")

  #run first population with parameters sampled from prior
  if verbose == true
    println("##################################################")
    println("Use ABC rejection to get first population")
  end
  ABCrejresults = runabcCancer(ABCRejectionModel(
            map(x -> x.simfunc, ABCsetup.Models),
            map(x -> x.nparams, ABCsetup.Models),
            ABCsetup.Models[1].ϵ1,
            map(x -> x.prior, ABCsetup.Models),
            constants = map(x -> x.constants, ABCsetup.Models),
            nparticles = ABCsetup.Models[1].nparticles,
            maxiterations = ABCsetup.Models[1].maxiterations),
            targetdata, progress = progress);

  oldparticles, weights = setupSMCparticles(ABCrejresults, ABCsetup)
  ϵ = quantile(ABCrejresults.dist, ABCsetup.α) # set new ϵ to αth quantile
  ϵvec = [ϵ] #store epsilon values
  numsims = [ABCrejresults.numsims] #keep track of number of simualtions
  particles = Array{ParticleSMCModel}(ABCsetup.nparticles) #define particles array
  weights, modelprob = getparticleweights(oldparticles, ABCsetup)

  modelprob = ABCrejresults.modelfreq

  if verbose == true
    println("Run ABC SMC \n")
  end

  popnum = 1
  finalpop = false

  if verbose == true
    show(ABCSMCmodelresults(oldparticles, numsims, ABCsetup, ϵvec))
  end

  newparticle, dist, out, priorp = 0.0,0.0,0.0,0.0

  while (ϵ >= ABCsetup.ϵT) & (sum(numsims) <= ABCsetup.maxiterations)
    if verbose == true
      println("######################################## \n")
      println("########################################")
      println("Population number: $(popnum) \n")
    end

    i = 1 #set particle indicator to 1
    particles = Array{ParticleSMCModel}(ABCsetup.nparticles)
    distvec = zeros(Float64, ABCsetup.nparticles)
    its = 1

    if progress == true
      p = Progress(ABCsetup.nparticles, 1, "ABC SMC population $(popnum), new ϵ: $(round(ϵ, 2))...", 30)
    end
    while i < ABCsetup.nparticles + 1

      #draw model from previous model probabilities
      mstar = wsample(1:ABCsetup.nmodels, modelprob)

      #perturb model
      mdoublestar = perturbmodel(ABCsetup, mstar, modelprob)
      correctmodel = false
      #sometimes even though the input is for multiple clones,
      #simulations will be returned that don't have the requested number of clones,
      #this can happen if for example the simulation finishes before t1 is reached.
      #To overcome this we continually resample until we get simulations with the correct number of clones
      while correctmodel == false
        # sample particle with correct model
        j = wsample(1:ABCsetup.nparticles, weights[mdoublestar, :])
        particletemp = oldparticles[j]
        #perturb particle
        newparticle = perturbparticle(particletemp)
        #calculate priorprob
        priorp = priorprob(newparticle.params, ABCsetup.Models[mdoublestar].prior)

        if priorp == 0.0 #return to beginning of loop if prior probability is 0
          break
        end

        #simulate with new parameters
        dist, out, cm = ABCsetup.Models[mdoublestar].simfunc(newparticle.params, ABCsetup.Models[mdoublestar].constants, targetdata)
        correctmodel = cm
      end

      if priorp == 0.0 #return to beginning of loop if prior probability is 0
        continue
      end

      #if simulated data is less than target tolerance accept particle
      if dist < ϵ
        particles[i] = newparticle
        particles[i].other = out
        particles[i].distance = dist
        distvec[i] = dist
        i += 1
        if progress == true
          next!(p)
        end
      end
      its += 1
    end

    particles, weights = smcweightsmodel(particles, oldparticles, ABCsetup, modelprob)
    weights, modelprob = getparticleweights(particles, ABCsetup)
    particles = getscales(particles, ABCsetup)
    oldparticles = deepcopy(particles)

    if finalpop == true
      break
    end

    ϵ = quantile(distvec, ABCsetup.α)

    if ϵ < ABCsetup.ϵT
      ϵ = ABCsetup.ϵT
      push!(ϵvec, ϵ)
      push!(numsims, its)
      popnum = popnum + 1
      finalpop = true
      continue
    end

    push!(ϵvec, ϵ)
    push!(numsims, its)

    if ((( abs(ϵvec[end - 1] - ϵ )) / ϵvec[end - 1]) < ABCsetup.convergence) == true
      println("New ϵ is within $(round(ABCsetup.convergence * 100, 2))% of previous population, stop ABC SMC")
      break
    end
    popnum = popnum + 1
    if verbose == true
      show(ABCSMCmodelresults(oldparticles, numsims, ABCsetup, ϵvec))
    end

    #sometimes models die out early in the inference, restart the process if this happens
    numdeadmodels = sum(modelprob.==0.0)
    deadmodels = collect(0:(ABCsetup.nmodels-1))[modelprob.==0.0]
    if (popnum <= 4) & (numdeadmodels > 0)
      warn("One of the models died out, restarting inference...")
      out = runabcCancer(ABCsetup, targetdata; verbose = verbose, progress = progress)
      return out
    end
  end

  out = ABCSMCmodelresults(particles, numsims, ABCsetup, ϵvec)
  return out
end

function runabcCancer(ABCsetup::ABCSMC, targetdata; verbose = false, progress = false)

  #run first population with parameters sampled from prior
  if verbose == true
    println("##################################################")
    println("Use ABC rejection to get first population")
  end
  ABCrejresults = runabc(ABCRejection(ABCsetup.simfunc, ABCsetup.nparams,
                  ABCsetup.ϵ1, ABCsetup.prior; nparticles = ABCsetup.nparticles,
                  maxiterations = ABCsetup.maxiterations, constants = ABCsetup.constants), targetdata);

  oldparticles, weights = setupSMCparticles(ABCrejresults, ABCsetup)
  ϵ = quantile(ABCrejresults.dist, ABCsetup.α) # set new ϵ to αth quantile
  ϵvec = [ϵ] #store epsilon values
  numsims = [ABCrejresults.numsims] #keep track of number of simualtions
  particles = Array{ParticleSMC}(ABCsetup.nparticles) #define particles array

  if verbose == true
    println("Run ABC SMC \n")
  end

  popnum = 1
  finalpop = false
  newparticle, dist, out, priorp = 0.0,0.0,0.0,0.0

  while (ϵ > ABCsetup.ϵT) & (sum(numsims) < ABCsetup.maxiterations)

    i = 1 #set particle indicator to 1
    particles = Array{ParticleSMC}(ABCsetup.nparticles)
    distvec = zeros(Float64, ABCsetup.nparticles)
    its = 1
    if progress == true
      p = Progress(ABCsetup.nparticles, 1, "ABC SMC population $(popnum), new ϵ: $(round(ϵ, 2))...", 30)
    end
    while i < ABCsetup.nparticles + 1

      correctmodel = false
      while correctmodel == false
        j = wsample(1:ABCsetup.nparticles, weights)
        particle = oldparticles[j]
        newparticle = perturbparticle(particle)
        priorp = priorprob(newparticle.params, ABCsetup.prior)
        if priorp == 0.0 #return to beginning of loop if prior probability is 0
          break
        end
        #simulate with new parameters
        dist, out, cm = ABCsetup.simfunc(newparticle.params, ABCsetup.constants, targetdata)
        correctmodel = cm
      end

    if priorp == 0.0 #return to beginning of loop if prior probability is 0
      continue
    end

      #if simulated data is less than target tolerance accept particle
      if dist < ϵ
        particles[i] = newparticle
        particles[i].other = out
        particles[i].distance = dist
        distvec[i] = dist
        i += 1
        if progress == true
          next!(p)
        end
      end

      its += 1
    end

    particles, weights = smcweights(particles, oldparticles, ABCsetup.prior)
    particles = getscales(particles, ABCsetup)
    oldparticles = deepcopy(particles)

    if finalpop == true
      break
    end

    ϵ = quantile(distvec, ABCsetup.α)

    if ϵ < ABCsetup.ϵT
      ϵ = ABCsetup.ϵT
      push!(ϵvec, ϵ)
      push!(numsims, its)
      popnum = popnum + 1
      finalpop = true
      continue
    end

    push!(ϵvec, ϵ)
    push!(numsims, its)

    if ((( abs(ϵvec[end - 1] - ϵ )) / ϵvec[end - 1]) < ABCsetup.convergence) == true
      if verbose == true
        println("New ϵ is within $(round(ABCsetup.convergence * 100, 2))% of previous population, stop ABC SMC")
    end
      break
    end

    popnum = popnum + 1
  end

  out = ABCSMCresults(particles, numsims, ABCsetup, ϵvec)
  return out
end
