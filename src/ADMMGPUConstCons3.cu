#include "../head/ADMMGPUConstCons3.cuh"

ADMMGPUConstCons3::ADMMGPUConstCons3() : MethodP2P()
{
#if DEBUG_CONSTRUCTOR
	std::cout << "Constructeur ADMMGPUConstCons3" << std::endl;
#endif // DEBUG_CONSTRUCTOR
	_name = NAME;
}


ADMMGPUConstCons3::ADMMGPUConstCons3(float rho) : MethodP2P()
{
#if DEBUG_CONSTRUCTOR
	std::cout << "Constructeur ADMMGPUConstCons3 defaut" << std::endl;
#endif // DEBUG_CONSTRUCTOR
	_name = NAME;
	_rho = rho;
}

ADMMGPUConstCons3::~ADMMGPUConstCons3()
{
	if (alpha != nullptr) {
		//std::cout << "delete alpha" << std::endl;
		cudaFree(alpha);
		alpha = nullptr;
	}
}

void ADMMGPUConstCons3::setParam(float rho)
{
	_rho = rho;
}

void ADMMGPUConstCons3::setTau(float tau)
{
	if (tau < 1) {
		throw std::invalid_argument("tau must be greater than 1");
	}
	_tau = tau;
}

void ADMMGPUConstCons3::init(const Simparam& sim, const StudyCase& cas)
{
	// intitilisation des matrixs et variables 
	_rhog = sim.getRho();
	_rho1 = sim.getRho1();
	
	//std::cout << "rho initial " << _rhog << std::endl;
	_nAgent = sim.getNAgent();
	
	_rhol = _rho;
	if (_rho == 0) {
		_rhol = _rhog;
	}
	const int iterG = sim.getIterG();
	const int stepG = sim.getStepG();
	float epsG = sim.getEpsG();
	float epsGC = sim.getEpsGC();
	_ratioEps = epsG / epsGC;
	
	nVoisinCPU = cas.getNvoi();
	nVoisin = MatrixGPU(nVoisinCPU, 1);

	int nVoisinMax = nVoisin.max2();
	if (_blockSize * NMAXPEERPERTRHREAD < nVoisinMax) {
		std::cout << _blockSize << " " << NMAXPEERPERTRHREAD << " " << nVoisinMax << std::endl;
		throw std::invalid_argument("For this Method, an agent must not have more than 5120 peers");
	}

	_nLine = cas.getNLine();
	L2 = 2 * _nLine;
	_Msize = _nAgent + L2 + 1;
	_Asize = L2 * _nAgent;
	std::cout << _nAgent << " " << _nLine << " " << _Msize << std::endl;
	
	_nBus = cas.getNBus();

	_nTrade = nVoisin.sum();
	_numBlocksN = ceil((_nAgent + _blockSize - 1) / _blockSize);
	_numBlocksM = ceil((_nTrade + _blockSize - 1) / _blockSize);
	_numBlocksL = ceil((_nLine + _blockSize - 1) / _blockSize);
	_numBlocksNL = ceil((_nAgent * _nLine + _blockSize - 1) / _blockSize);
	_at1 = _rhog; // represente en fait 2*a
	_at2 = _rhol;

	resF = MatrixCPU(3, (iterG / stepG) + 1);
	resX = MatrixCPU(4, (iterG / stepG) + 1);

	MatrixCPU BETA(cas.getBeta());
	MatrixGPU Ub(cas.getUb());
	MatrixGPU Lb(cas.getLb());
	LAMBDA = sim.getLambda();
	trade = sim.getTrade();
	
	//std::cout << "mise sous forme lin�aire" << std::endl;
	// Rem : si matrice d�j� existante, elles sont d�j� sur GPU donc bug pour les get

	CoresMatLin = MatrixGPU(_nAgent, _nAgent, -1);
	CoresLinAgent = MatrixGPU(_nTrade, 1);
	CoresAgentLin = MatrixGPU(_nAgent + 1, 1);
	CoresLinVoisin = MatrixGPU(_nTrade, 1);
	CoresLinTrans = MatrixGPU(_nTrade, 1);
	
	Tlocal_pre = MatrixGPU(_nTrade, 1);
	tradeLin = MatrixGPU(_nTrade, 1);
	LAMBDALin = MatrixGPU(_nTrade, 1);

	matLb = MatrixGPU(_nTrade, 1);
	matUb = MatrixGPU(_nTrade, 1);
	Ct = MatrixGPU(_nTrade, 1);

	int indice = 0;

	for (int idAgent = 0; idAgent < _nAgent; idAgent++) {
		MatrixCPU omega(cas.getVoisin(idAgent));
		int Nvoisinmax = nVoisinCPU.get(idAgent, 0);
		for (int voisin = 0; voisin < Nvoisinmax; voisin++) {
			int idVoisin = omega.get(voisin, 0);
			if(Lb.getNCol()==1){
				matLb.set(indice, 0, Lb.get(idAgent, 0));
				matUb.set(indice, 0, Ub.get(idAgent, 0));
			} else {
				matLb.set(indice, 0, Lb.get(idAgent, idVoisin));
				matUb.set(indice, 0, Ub.get(idAgent, idVoisin));
			}
			Ct.set(indice, 0, BETA.get(idAgent, idVoisin));
			tradeLin.set(indice, 0, trade.get(idAgent, idVoisin));
			Tlocal_pre.set(indice, 0, trade.get(idAgent, idVoisin));
			LAMBDALin.set(indice, 0, LAMBDA.get(idAgent, idVoisin));
			CoresLinAgent.set(indice, 0, idAgent);
			CoresLinVoisin.set(indice, 0, idVoisin);
			CoresMatLin.set(idAgent, idVoisin, indice);
			indice = indice + 1;
		}
		CoresAgentLin.set(idAgent + 1, 0, indice);
	}
	for (int lin = 0; lin < _nTrade; lin++) {
		int i = CoresLinAgent.get(lin, 0);
		int j = CoresLinVoisin.get(lin, 0);
		int k = CoresMatLin.get(j, i);
		CoresLinTrans.set(lin, 0, k);
	}


	// transfert des mises lineaire
	matUb.transferGPU();
	matLb.transferGPU();
	Ct.transferGPU();

	Tlocal_pre.transferGPU();
	tradeLin.transferGPU();
	LAMBDALin.transferGPU();

	CoresAgentLin.transferGPU();
	CoresLinAgent.transferGPU();
	CoresLinVoisin.transferGPU();
	CoresMatLin.transferGPU();
	CoresLinTrans.transferGPU();
	
	
	
	//std::cout << "donnees sur GPU pour le grid" << std::endl;
	if (_nLine) {
		
		cudaMalloc((void**)&alpha, sizeof(float));
		tempL21 = MatrixGPU(L2 + 1, 1, 0, 1);

		H = MatrixGPU(_nAgent, _nAgent, 0, 1);
		H.setEyes(_rho1);

		q = MatrixGPU(_nAgent, 1, 0, 1); // 0.5x^THx + q^T*x
		diffPso = MatrixGPU(_nAgent, 1, 0, 1);

		c = MatrixGPU(L2 + 1, 1, 0, 1); // contrainte Ax+b>0 ou = 0 pour egalit�
		Ai = MatrixGPU(L2 + 1, _nAgent, 0, 1);
		MatrixGPU ones(1, _nAgent, 1, 1);
		MatrixGPU temp(cas.getPowerSensi(), 1);
		Ai.setBloc(0, _nLine, 0, _nAgent, &temp, -1);
		Ai.setBloc(_nLine, L2, 0, _nAgent, &temp);
		Ai.setBloc(L2, L2 + 1, 0, _nAgent, &ones);
		bi = MatrixGPU(L2 + 1, 1, 0, 1);
		lLimit = MatrixGPU(cas.getLineLimit(), 1);
		bi.setBloc(0, _nLine, 0, 1, &lLimit);
		bi.setBloc(_nLine, L2, 0, 1, &lLimit);

		M = MatrixGPU(_Msize, _Msize, 0, 1); // M*pas = R
		Minv = MatrixGPU(_Msize, _Msize, 0, 1); // M*pas = R
		pas = MatrixGPU(_Msize, 1, 0, 1);
		R = MatrixGPU(_Msize, 1, 0, 1);


		ZA = MatrixGPU(L2 + 1, _nAgent, 0, 1); // M = (H -Atrans ZA W)
		Z = MatrixGPU(L2 + 1, L2 + 1, 0, 1);
		Zvect = MatrixGPU(L2 + 1, 1, 0, 1);
		W = MatrixGPU(L2 + 1, L2 + 1, 0, 1);
		Wvect = MatrixGPU(L2 + 1, 1, 0, 1);
		Atrans = MatrixGPU(_nAgent, L2 + 1, 0, 1);
		Atrans.setTrans(&Ai);

		M.setBloc(0, _nAgent, 0, _nAgent, &H);
		M.setBloc(0, _nAgent, _nAgent, _Msize, &Atrans, -1);

			

		Rx1 = MatrixGPU(_nAgent, 1, 0, 1); // Hx+q
		Rx2 = MatrixGPU(_nAgent, 1, 0, 1); // -Ai^T*U

		Ru = MatrixGPU(L2 + 1, 1, 0, 1); // Ru = W*(U-PI)

		U = MatrixGPU(L2 + 1, 1, 0, 1);
		PI = MatrixGPU(L2 + 1, 1, 0, 1);
		
		Apas = MatrixGPU(L2 + 1, 1, 0, 1);
		
	}
	Pso = MatrixGPU(_nAgent, 1, 0, 1); // = Pn ? risque de non respect des contraintes
	
	etaP = MatrixGPU(_nAgent, 1, 0, 1); 

	//std::cout << "autres donn�e sur GPU" << std::endl;
	tempNN = MatrixGPU(_nTrade, 1, 0, 1);
	tempN1 = MatrixGPU(_nAgent, 1, 0, 1); // plut�t que de re-allouer de la m�moire � chaque utilisation
	tempL1 = MatrixGPU(_nLine, 1, 0, 1);
	tempL2 = MatrixGPU(_nLine, 1, 0, 1);
	//MatrixGPU temp1N(1, _nAgent, 0, 1);

	Tlocal = MatrixGPU(_nTrade, 1, 0, 1);
	P = MatrixGPU(_nAgent, 1, 0, 1); // moyenne des trades
	Pn = MatrixGPU(sim.getPn(), 1); // somme des trades


	a = MatrixGPU(cas.geta(), 1);
	b = MatrixGPU(cas.getb(), 1);
	Ap2 = a;
	Ap1 = nVoisin;
	Ap3 = nVoisin;
	Ap123 = MatrixGPU(_nAgent, 1, 0, 1);
	Bp3 = MatrixGPU(_nAgent, 1, 0, 1); // 1/Mn * (Pso + P)/2 - eta/rho1

	Bt1 = MatrixGPU(_nTrade, 1, 0, 1);
	Cp = b;

	Pmin = MatrixGPU(cas.getPmin(), 1);
	Pmax = MatrixGPU(cas.getPmax(), 1);
	MU = MatrixGPU(sim.getMU(), 1); // facteur reduit i.e lambda_l/_rho
	Tmoy = MatrixGPU(sim.getPn(), 1);

	tempNN.preallocateReduction();
	Tlocal.preallocateReduction();
	tempL1.preallocateReduction();
	R.preallocateReduction();

	P.preallocateReduction();
	Pso.preallocateReduction();


	Pmin.divideT(&nVoisin);
	Pmax.divideT(&nVoisin);
	Ap1.multiply(_rhol);
	Ap3.multiplyT(&nVoisin);
	Ap3.multiply(_rho1);
	Cp.multiplyT(&nVoisin);
	Tmoy.divideT(&nVoisin);

	Ap2.multiplyT(&nVoisin);
	Ap2.multiplyT(&nVoisin);
	Ap123.add(&Ap1, &Ap2);
	Ap123.add(&Ap3);
	
	
	
	updateGlobalProbGPU(epsG);

	
	
	//std::cout << " end init " << std::endl;
}



void ADMMGPUConstCons3::updateP0(const StudyCase& cas)
{
	_id = _id + 1;
#ifdef INSTRUMENTATION
	cudaDeviceSynchronize();
	std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
#endif // INSTRUMENTATION

	matLb.transferCPU();
	
	Pmin = MatrixGPU(cas.getPmin());
	Pmax = MatrixGPU(cas.getPmax());


	MatrixGPU Lb(cas.getLb());

	b = cas.getb();
	Cp = cas.getb();
	int indice = 0;

	for (int idAgent = 0; idAgent < _nAgent; idAgent++) {
		int Nvoisinmax = nVoisinCPU.get(idAgent, 0);
		for (int voisin = 0; voisin < Nvoisinmax; voisin++) {
			matLb.set(indice, 0, Lb.get(idAgent, 0));
			indice = indice + 1;
		}
	}

	
	matLb.transferGPU();

	Pmin.divideT(&nVoisin);
	Pmax.divideT(&nVoisin);
	Cp.multiplyT(&nVoisin);
#ifdef INSTRUMENTATION
	cudaDeviceSynchronize();
	std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();
	timePerBlock.increment(0, 10, std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1).count());
	occurencePerBlock.increment(0, 10, 1);
#endif // INSTRUMENTATION

	//std::cout << "fin update temps : " << (float)(clock() - t) / CLOCKS_PER_SEC << std::endl;
}

void ADMMGPUConstCons3::solveOPF(float epsOPF)
{
	
	// update q
    diffPso.set(&Pso);
	q.set(&etaP);
	diffPso.add(&Pn);
	diffPso.multiply(-_rho1/2);
	q.add(&diffPso);
	
	//init
	int k = 0;
	int kmax = 1000;
	
	float err = 2 * epsOPF;
	mu = 10;
	float valMin = 0.0000001;
	//boucle
	while (k<kmax && err>epsOPF) {
	// update c
		
		c.linearOperation(&Ai, &Pso, &bi);
		
	// update PI
		/*c.transferCPU();
		PI.transferCPU();
		for (int l = 0; l < L2; l++) {
			if (c.get(l, 0) < valMin) {
				PI.set(l, 0, mu / valMin); // eviter division par O
			}
			else {
				PI.set(l, 0, mu / c.get(l, 0)); // eviter division par O
			}
		}
		PI.set(L2, 0, -c.get(L2, 0) / mu);
		PI.transferGPU();
		c.transferGPU();*/
		updatePI << <_numBlocksL, _blockSize >> > (PI._matrixGPU, c._matrixGPU, mu, valMin, L2);
	
	// update M
		// update Zvect
		Zvect.set(&U); 
		
		Zvect.set(L2, 0, 1, true); // egalite
		// update Z
		Z.setEyes(&Zvect);
		// update ZA
		ZA.multiplyMat(&Z, &Ai);
		// update W
		Wvect.set(&c);
		Wvect.set(L2, 0, mu, true);
		W.setEyes(&Wvect);

		M.setBloc(_nAgent, _Msize, 0, _nAgent, &ZA);
		M.setBloc(_nAgent, _Msize, _nAgent, _Msize, &W);
		try
		{
			Minv.invertGaussJordan(&M);
		}
		catch (const std::exception& e)
		{
			std::cout << e.what() << std::endl;
			float alphaCPU;
			cudaMemcpy(&alphaCPU, alpha, sizeof(float), cudaMemcpyDeviceToHost);
			std::cout << "k = " << k << " err= " << err << " alpha = " << alphaCPU  << " mu=" << mu << std::endl;
			c.display(true);
			Pn.display(true);
			Pso.display(true);
			std::cout << "---------------------------------" << std::endl;
			Pso.set(&Pn);
			return;
		}
		
	
	//update R
		// Rx
		Rx1.linearOperation(&H, &Pso, &q);
		Rx2.multiply(&Atrans, &U);
		Rx2.subtract(&Rx1);
		// Ru
		tempL21.subtract(&PI, &U);
		Ru.multiply(&W, &tempL21);

		R.setBloc(0, _nAgent, 0, 1, &Rx2);
		R.setBloc(_nAgent, _Msize, 0, 1, &Ru);
		//update pas
		pas.multiply(&Minv, &R);
		// find alpha
		findalpha();
		/*float alphaCPU;
		cudaMemcpy(&alphaCPU, alpha, sizeof(float), cudaMemcpyDeviceToHost);
		
		if (alphaCPU < valMin) { // trop proche de la froncti�re
			std::cout << "alpha " << alphaCPU << std::endl;
			c.display(true);
			Pso.display(true);
			Pn.display(true);
			break;
		}*/
		
		// update P, U
		updatePso << <_numBlocksN, _blockSize >> > (Pso._matrixGPU, pas._matrixGPU, alpha, _nAgent);
		updateU << <_numBlocksL, _blockSize >> > (U._matrixGPU, pas._matrixGPU, alpha, _nAgent, L2 + 1);

		

		// update mu
		mu *= 0.8;
		mu = MAX(mu, valMin);
		//R.transferCPU();
		err = R.distance2();
		//R.transferGPU();
		k++;
	}
	//std::cout << k << " " << err << std::endl;
}



void ADMMGPUConstCons3::findalpha()
{
	

	int numBlock = L2;
	switch (_blockSize) {
	case 512:
		updateAPas<512> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha<512> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case 256:
		updateAPas<256> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha<256> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case 128:
		updateAPas<128> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha<128> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case 64:
		updateAPas< 64> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha< 64> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case 32:
		updateAPas< 32> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha< 32> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case 16:
		updateAPas< 16> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha< 16> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case  8:
		updateAPas<  8> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha< 8> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case  4:
		updateAPas<  4> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha<  4> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case  2:
		updateAPas<  2> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha<  2> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	case  1:
		updateAPas<  1> << <numBlock, _blockSize >> > (Apas._matrixGPU, Ai._matrixGPU, pas._matrixGPU, _nAgent);
		updateAlpha<  1> << <1, _blockSize >> > (alpha, U._matrixGPU, pas._matrixGPU, c._matrixGPU, Apas._matrixGPU, _nAgent, L2);
		break;
	}
	

	// truc avec alpha et beta pour optimiser sa valeur


}




void ADMMGPUConstCons3::solve(Simparam* result, const Simparam& sim, const StudyCase& cas)
{
#ifdef DEBUG_SOLVE
	cas.display();
	sim.display(1);
#endif // DEBUG_SOLVE
	
	
	clock_t tall = clock();
#ifdef INSTRUMENTATION
	std::chrono::high_resolution_clock::time_point t1;
	std::chrono::high_resolution_clock::time_point t2;
#endif // INSTRUMENTATION

	if (_id == 0) {
#ifdef INSTRUMENTATION
		cudaDeviceSynchronize();
		t1 = std::chrono::high_resolution_clock::now();
#endif // INSTRUMENTATION
		init(sim, cas);
#ifdef INSTRUMENTATION
		cudaDeviceSynchronize();
		t2 = std::chrono::high_resolution_clock::now();
		timePerBlock.increment(0, 0, std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1).count());
		occurencePerBlock.increment(0, 0, 1);
#endif // INSTRUMENTATION
	}
	//std::cout << _numBlocks2 << " " <<  _blockSize << std::endl;
	
	_at1 = _rhog; // represente en fait 2*a
	
	float epsG = sim.getEpsG();
	float epsL = sim.getEpsL();
	float epsOPF = epsL / _ratioEps;
	const int stepL = sim.getStepL();
	const int stepG = sim.getStepG();
	const int iterG = sim.getIterG();
	const int iterL = sim.getIterL();
	

	float resG = 2 * epsG;
	float epsL2 = epsL * epsL;
	int iterGlobal = 0;
	int iterLocal = 0;
	int realOccurence = 0;
	
	//std::cout << iterG << " " << iterL << " " << epsL << " " << epsG << std::endl;
	while ((iterGlobal < iterG) && (resG > epsG)) {
#ifdef INSTRUMENTATION
		cudaDeviceSynchronize();
		t1 = std::chrono::high_resolution_clock::now();
#endif // INSTRUMENTATION

		updateLocalProbGPU(epsL2, iterL);
#ifdef INSTRUMENTATION
		cudaDeviceSynchronize();
		t2 = std::chrono::high_resolution_clock::now();
		timePerBlock.increment(0, 1, std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1).count());
#endif // INSTRUMENTATION

		tradeLin.swap(&Tlocal); // echange juste les pointeurs	
		//std::cout << "-";
		
		updateGlobalProbGPU(epsOPF);
		
		if (!(iterGlobal % stepG)) {
#ifdef INSTRUMENTATION
			cudaDeviceSynchronize();
			t1 = std::chrono::high_resolution_clock::now();
#endif // INSTRUMENTATION
			resG = updateRes(&resF, &Tlocal, iterGlobal / stepG, &tempNN);
#ifdef INSTRUMENTATION
			cudaDeviceSynchronize();
			t2 = std::chrono::high_resolution_clock::now();
			timePerBlock.increment(0, 8, std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1).count());
#endif // INSTRUMENTATION
		}
		//std::cout << iterGlobal << " " << iterLocal << " " << resL << " " << resF.get(0, iterGlobal / stepG) << " " << resF.get(1, iterGlobal / stepG) << std::endl;
		iterGlobal++;
	}
#ifdef INSTRUMENTATION
	occurencePerBlock.increment(0, 1, iterGlobal);
	occurencePerBlock.increment(0, 5, iterGlobal);
	occurencePerBlock.increment(0, 6, iterGlobal);
	occurencePerBlock.increment(0, 7, iterGlobal);
	occurencePerBlock.increment(0, 8, iterGlobal / stepG);

	cudaDeviceSynchronize();
	t1 = std::chrono::high_resolution_clock::now();
#endif // INSTRUMENTATION
	
	

	float fc = calcFc(&a, &b, &tradeLin, &Pn, &Ct, &tempN1, &tempNN);
	//std::cout << iterGlobal << " " << iterLocal << " " << resL << " " << resG << std::endl;
	std::cout << "valeur finale des contraintes de l'opf : " << std::endl;
	
	c.display(true);
	MatrixCPU tradeLinCPU;
	tradeLin.toMatCPU(tradeLinCPU);
	MatrixCPU LAMBDALinCPU;
	LAMBDALin.toMatCPU(LAMBDALinCPU);
	MatrixCPU PnCPU;
	Pn.toMatCPU(PnCPU);
	MatrixCPU MUCPU;
	MU.toMatCPU(MUCPU);
	

	int indice = 0;
	for (int idAgent = 0;idAgent < _nAgent; idAgent++) {
		MatrixCPU omega(cas.getVoisin(idAgent));
		int Nvoisinmax = nVoisinCPU.get(idAgent, 0);
		for (int voisin = 0; voisin < Nvoisinmax; voisin++) {
			int idVoisin = omega.get(voisin, 0);
			trade.set(idAgent, idVoisin, tradeLinCPU.get(indice, 0));
			LAMBDA.set(idAgent, idVoisin, LAMBDALinCPU.get(indice, 0));
			indice = indice + 1;
		}
	}
	result->setResF(&resF);
	result->setLAMBDA(&LAMBDA);
	result->setTrade(&trade);
	
	result->setIter(iterGlobal);
	result->setPn(&PnCPU);
	result->setFc(fc);
	result->setMU(&MUCPU);
	result->setRho(_rhog);
#ifdef INSTRUMENTATION
	cudaDeviceSynchronize();
	t2 = std::chrono::high_resolution_clock::now();
	timePerBlock.increment(0, 9, std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1).count());
	occurencePerBlock.increment(0, 9, 1);
	result->setTimeBloc(&timePerBlock, &occurencePerBlock);
#endif // INSTRUMENTATION

	tall = clock() - tall;
	result->setTime((float)tall / CLOCKS_PER_SEC);
}

void ADMMGPUConstCons3::updateLocalProbGPU(float epsL, int nIterL) {
	int numBlocks = _nAgent;
	switch (_blockSize) {
	case 512:
		updateTradePGPUSharedResidualCons<512> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case 256:
		updateTradePGPUSharedResidualCons<256> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case 128:
		updateTradePGPUSharedResidualCons<128> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case 64:
		updateTradePGPUSharedResidualCons< 64> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case 32:
		updateTradePGPUSharedResidualCons< 32> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case 16:
		updateTradePGPUSharedResidualCons< 16> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case  8:
		updateTradePGPUSharedResidualCons<  8> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case  4:
		updateTradePGPUSharedResidualCons<  4> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case  2:
		updateTradePGPUSharedResidualCons<  2> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	case  1:
		updateTradePGPUSharedResidualCons<  1> << <numBlocks, _blockSize >> > (Tlocal._matrixGPU, Tlocal_pre._matrixGPU, Tmoy._matrixGPU, P._matrixGPU, MU._matrixGPU, nVoisin._matrixGPU, _at1, _at2, Bt1._matrixGPU, Ct._matrixGPU,
			matLb._matrixGPU, matUb._matrixGPU, Ap1._matrixGPU, Ap3._matrixGPU, Ap123._matrixGPU, Bp3._matrixGPU, Cp._matrixGPU, Pmin._matrixGPU, Pmax._matrixGPU, CoresAgentLin._matrixGPU, epsL, nIterL);
		break;
	}
	//cudaStreamSynchronize(streamCalculation);
}



void ADMMGPUConstCons3::updateGlobalProbGPU(float epsOPF)
{
	//Rem : tout calcul qui est de taille N ou M peut �tre fait par les agents
		// Si le calcul est de taile L, soit c'est calcul� par un/des superviseurs, soit tous les agents le calcul (un peu absurde)

#ifdef INSTRUMENTATION
// FB 3a
	cudaDeviceSynchronize();
	std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
#endif // INSTRUMENTATION


	updatePnGPU << <_numBlocksN, _blockSize >> > (Pn._matrixGPU, Tmoy._matrixGPU, nVoisin._matrixGPU, _nAgent);
	
#ifdef INSTRUMENTATION
	cudaDeviceSynchronize();
	std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();

	timePerBlock.increment(0, 5, std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1).count());

	// FB 3b
	cudaDeviceSynchronize();
	t1 = std::chrono::high_resolution_clock::now();
#endif // INSTRUMENTATION	

	// Resolution de l'OPF
	if (_nLine) {
		
		
		//std::cout << " Pn :" << std::endl;
		//Pn.display(true);
		//std::cout << " etaP :" << std::endl;
		//etaP.display(true);

		solveOPF(epsOPF);
		//std::cout << " Pso :" << std::endl;
		//Pso.display(true);
		
		
	}
	else {
		Pso = Pn;
		/*tempN1.set(&etaP);
		tempN1.divide(_rho1);
		Pso.add(&Pn);
		Pso.divide(2);
		Pso.subtract(&tempN1);*/
	}
	
	
	

#ifdef INSTRUMENTATION
	cudaDeviceSynchronize();
	t2 = std::chrono::high_resolution_clock::now();
	timePerBlock.increment(0, 6, std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1).count());

	// FB 3c
	cudaDeviceSynchronize();
	t1 = std::chrono::high_resolution_clock::now();
#endif // INSTRUMENTATION

	// update Bp3
	updateEtaPBp3 << <_numBlocksN, _blockSize >> > (Bp3._matrixGPU, etaP._matrixGPU, nVoisin._matrixGPU, Pso._matrixGPU, Pn._matrixGPU, _rho1, _nAgent);
	updateLAMBDABt1GPU << <_numBlocksM, _blockSize >> > (Bt1._matrixGPU, LAMBDALin._matrixGPU, tradeLin._matrixGPU, _rhog, CoresLinTrans._matrixGPU, _nTrade);
	

#ifdef INSTRUMENTATION
	cudaDeviceSynchronize();
	t2 = std::chrono::high_resolution_clock::now();
	timePerBlock.increment(0, 7, std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1).count());
#endif // INSTRUMENTATION
}



float ADMMGPUConstCons3::updateRes(MatrixCPU* res, MatrixGPU* Tlocal, int iter, MatrixGPU* tempNN)
{

	float resS = Tlocal->max2(&tradeLin);

	updateDiffGPU <<<_numBlocksM, _blockSize >> > (tempNN->_matrixGPU, Tlocal->_matrixGPU, CoresLinTrans._matrixGPU, _nAgent);
	float resR = tempNN->max2();

	float resXf = _ratioEps * Pso.max2(&Pn);
	res->set(0, iter, resR);
	res->set(1, iter, resS);
	res->set(2, iter, resXf);
	return MAX(MAX(resXf, resS), resR);

}





void ADMMGPUConstCons3::display() {

	std::cout << _name << std::endl;
}


