import BeeDataset
import PenguinStructures
import SwiftFusion
import TensorFlow
import PythonKit
import Foundation

/// A factor that specifies a prior on a pose.
public struct WeightedPriorFactor<Pose: LieGroup>: LinearizableFactor1 {
  public let edges: Variables.Indices
  public let prior: Pose
  public let weight: Double

  public init(_ id: TypedID<Pose>, _ prior: Pose, weight: Double) {
    self.edges = Tuple1(id)
    self.prior = prior
    self.weight = weight
  }

  @differentiable
  public func errorVector(_ x: Pose) -> Pose.TangentVector {
    return weight * prior.localCoordinate(x)
  }
}

/// A factor that specifies a difference between two poses.
public struct WeightedBetweenFactor<Pose: LieGroup>: LinearizableFactor2 {
  public let edges: Variables.Indices
  public let difference: Pose
  public let weight: Double

  public init(_ startId: TypedID<Pose>, _ endId: TypedID<Pose>, _ difference: Pose, weight: Double) {
    self.edges = Tuple2(startId, endId)
    self.difference = difference
    self.weight = weight
  }

  @differentiable
  public func errorVector(_ start: Pose, _ end: Pose) -> Pose.TangentVector {
    let actualMotion = between(start, end)
    return weight * difference.localCoordinate(actualMotion)
  }
}

public struct WeightedBetweenFactorPose2: LinearizableFactor2 {
  public typealias Pose = Pose2
  public let edges: Variables.Indices
  public let difference: Pose
  public let weight: Double
  public let rotWeight: Double

  public init(_ startId: TypedID<Pose>, _ endId: TypedID<Pose>, _ difference: Pose, weight: Double, rotWeight: Double = 1.0) {
    self.edges = Tuple2(startId, endId)
    self.difference = difference
    self.weight = weight
    self.rotWeight = rotWeight
  }

  @differentiable
  public func errorVector(_ start: Pose, _ end: Pose) -> Pose.TangentVector {
    let actualMotion = between(start, end)
    let weighted = weight * difference.localCoordinate(actualMotion)
    return Vector3(rotWeight * weighted.x, weighted.y, weighted.z)
  }
}

public struct WeightedBetweenFactorPose2SD: LinearizableFactor2 {
  public typealias Pose = Pose2
  public let edges: Variables.Indices
  public let difference: Pose

  public let sdX: Double
  public let sdY: Double
  public let sdTheta: Double

  public init(_ startId: TypedID<Pose>, _ endId: TypedID<Pose>, _ difference: Pose, sdX: Double, sdY: Double, sdTheta: Double) {
    self.edges = Tuple2(startId, endId)
    self.difference = difference
    self.sdX = sdX
    self.sdY = sdY
    self.sdTheta = sdTheta
  }

  @differentiable
  public func errorVector(_ start: Pose, _ end: Pose) -> Pose.TangentVector {
    let actualMotion = between(start, end)
    let local = difference.localCoordinate(actualMotion)
    return Vector3(local.x / sdTheta, local.y / sdX, local.z / sdY)
  }
}

public struct WeightedPriorFactorPose2: LinearizableFactor1 {
  public typealias Pose = Pose2
  public let edges: Variables.Indices
  public let prior: Pose
  public let weight: Double
  public let rotWeight: Double

  public init(_ startId: TypedID<Pose>, _ prior: Pose, weight: Double, rotWeight: Double = 1.0) {
    self.edges = Tuple1(startId)
    self.prior = prior
    self.weight = weight
    self.rotWeight = rotWeight
  }

  @differentiable
  public func errorVector(_ start: Pose) -> Pose.TangentVector {
    let weighted = weight * prior.localCoordinate(start)
    return Vector3(rotWeight * weighted.x, weighted.y, weighted.z)
  }
}

public struct WeightedPriorFactorPose2SD: LinearizableFactor1 {
  public typealias Pose = Pose2
  public let edges: Variables.Indices
  public let prior: Pose
  public let sdX: Double
  public let sdY: Double
  public let sdTheta: Double

  public init(_ startId: TypedID<Pose>, _ prior: Pose, sdX: Double, sdY: Double, sdTheta: Double) {
    self.edges = Tuple1(startId)
    self.prior = prior
    self.sdX = sdX
    self.sdY = sdY
    self.sdTheta = sdTheta
  }

  @differentiable
  public func errorVector(_ start: Pose) -> Pose.TangentVector {
    let local = prior.localCoordinate(start)
    return Vector3(local.x / sdTheta, local.y / sdX, local.z / sdY)
  }
}

/// A specification for a factor graph that tracks a target in a sequence of frames.
public struct TrackingConfiguration<FrameVariables: VariableTuple> {
  /// The frames of the video to track.
  public var frames: [Tensor<Float>]

  /// A collection of arbitrary values for the variables in the factor graph.
  public let variableTemplate: VariableAssignments

  /// The ids of the variables in each frame.
  public let frameVariableIDs: [FrameVariables.Indices]

  /// Adds to `graph` a prior factor on `variables`
  public let addPriorFactor: (
    _ variables: FrameVariables.Indices, _ values: FrameVariables, _ graph: inout FactorGraph
  ) -> ()

  /// Adds to `graph` a tracking factor on `variables` for tracking in `frame`.
  public let addTrackingFactor: (
    _ variables: FrameVariables.Indices, _ frame: Tensor<Float>, _ graph: inout FactorGraph
  ) -> ()

  /// Adds to `graph` between factor(s) between the variables at `variables1` and the variables at `variables2`.
  public let addBetweenFactor: (
    _ variables1: FrameVariables.Indices, _ variables2: FrameVariables.Indices,
    _ graph: inout FactorGraph
  ) -> ()

  /// Adds to `graph` "between factor(s)" between `constantVariables` and `variables` that treat
  /// the `constantVariables` as fixed.
  ///
  /// This is used during frame-by-frame initialization to constrain frame `i + 1` by a between
  /// factor on the value from frame `i` without optimizing the value of frame `i`.
  public let addFixedBetweenFactor: (
    _ values: FrameVariables, _ variables: FrameVariables.Indices,
    _ graph: inout FactorGraph
  ) -> ()

  /// The optimizer to use during inference.
  public var optimizer = LM()

  /// Creates an instance.
  ///
  /// See the field doc comments for argument docs.
  public init(
    frames: [Tensor<Float>],
    variableTemplate: VariableAssignments,
    frameVariableIDs: [FrameVariables.Indices],
    addPriorFactor: @escaping (
      _ variables: FrameVariables.Indices, _ values: FrameVariables, _ graph: inout FactorGraph
    ) -> (),
    addTrackingFactor: @escaping (
      _ variables: FrameVariables.Indices, _ frame: Tensor<Float>, _ graph: inout FactorGraph
    ) -> (),
    addBetweenFactor: @escaping (
      _ variables1: FrameVariables.Indices, _ variables2: FrameVariables.Indices,
      _ graph: inout FactorGraph
    ) -> (),
    addFixedBetweenFactor: ((
      _ values: FrameVariables, _ variables: FrameVariables.Indices,
      _ graph: inout FactorGraph
    ) -> ())? = nil
  ) {
    precondition(
      addFixedBetweenFactor != nil,
      "I added a runtime check for this argument so that I would not have to change all " +
        "callers before compiling. It is actually required."
    )

    self.frames = frames
    self.variableTemplate = variableTemplate
    self.frameVariableIDs = frameVariableIDs
    self.addPriorFactor = addPriorFactor
    self.addTrackingFactor = addTrackingFactor
    self.addBetweenFactor = addBetweenFactor
    self.addFixedBetweenFactor = addFixedBetweenFactor!

    self.optimizer.precision = 1e-1
    self.optimizer.max_iteration = 100
    self.optimizer.cgls_precision = 1e-5
  }

  /// Returns a `FactorGraph` for the tracking problem on the frames at `frameIndices`.
  public func graph(on frameIndices: Range<Int>) -> FactorGraph {
    var result = FactorGraph()
    for i in frameIndices {
      addTrackingFactor(frameVariableIDs[i], frames[i], &result)
    }
    for i in frameIndices.dropLast() {
      addBetweenFactor(frameVariableIDs[i], frameVariableIDs[i + 1], &result)
    }
    return result
  }

  /// Returns a prediction.
  public mutating func infer(
    knownStart: FrameVariables
  ) -> VariableAssignments {
    // Set the first variable to the known starting position.
    var x = variableTemplate
    x[frameVariableIDs[0]] = knownStart

    // Initialize the variables one frame at a time. Each iteration intializes the `i+1`-th
    // variable.
    for i in 0..<(frames.count - 1) {
      print("Inferring for frame \(i + 1) of \(frames.count - 1)")

      // Set the initial guess of the `i+1`-th variable to the value of the previous variable.
      x[frameVariableIDs[i + 1]] = x[frameVariableIDs[i], as: FrameVariables.self]

      // Create a tracking factor graph on just the `i+1`-th variable.
      var g = graph(on: (i + 1)..<(i + 2))

      // The `i`-th variable is already initialized well, so add a prior factor that it stays
      // near its current position.
      addFixedBetweenFactor(x[frameVariableIDs[i]], frameVariableIDs[i + 1], &g)

      let previousVarID = (frameVariableIDs[i] as! Tuple1<TypedID<Pose2>>).head
      let currentVarID = (frameVariableIDs[i + 1] as! Tuple1<TypedID<Pose2>>).head
      let previousPose = x[previousVarID]
      var bestPose = x[currentVarID]
      var bestError = g.error(at: x)
      for _ in 0..<5 {
        let noise = Tensor<Double>(randomNormal: [3]).scalars
        x[currentVarID] = previousPose.retract(Vector3(
          0.3 * noise[0],
          8 * noise[1],
          4.6 * noise[2]))
        try? optimizer.optimize(graph: g, initial: &x)
        let candidateError = g.error(at: x)
        if candidateError < bestError {
          bestError = candidateError
          bestPose = x[currentVarID]
        }
      }
      x[currentVarID] = bestPose
    }

    // We could also do a final optimization on all the variables jointly here.

    return x
  }
}

/// Returns a tracking configuration for a tracker using an RAE.
///
/// Parameter model: The RAE model to use.
/// Parameter statistics: Normalization statistics for the frames.
/// Parameter frames: The frames of the video where we want to run tracking.
/// Parameter targetSize: The size of the target in the frames.
public func makeRAETracker(
  model: DenseRAE,
  statistics: FrameStatistics,
  frames: [Tensor<Float>],
  targetSize: (Int, Int)
) -> TrackingConfiguration<Tuple2<Pose2, Vector10>> {
  var variableTemplate = VariableAssignments()
  var frameVariableIDs = [Tuple2<TypedID<Pose2>, TypedID<Vector10>>]()
  for _ in 0..<frames.count {
    frameVariableIDs.append(
      Tuple2(
        variableTemplate.store(Pose2()),
        variableTemplate.store(Vector10())))
  }
  return TrackingConfiguration(
    frames: frames,
    variableTemplate: variableTemplate,
    frameVariableIDs: frameVariableIDs,
    addPriorFactor: { (variables, values, graph) -> () in
      let (poseID, latentID) = unpack(variables)
      let (pose, latent) = unpack(values)
      graph.store(WeightedPriorFactor(poseID, pose, weight: 1e-2))
      graph.store(WeightedPriorFactor(latentID, latent, weight: 1e2))
    },
    addTrackingFactor: { (variables, frame, graph) -> () in
      let (poseID, latentID) = unpack(variables)
      graph.store(
        AppearanceTrackingFactor<Vector10>(
          poseID, latentID,
          measurement: statistics.normalized(frame),
          appearanceModel: { x in
            model.decode(x.expandingShape(at: 0)).squeezingShape(at: 0)
          },
          appearanceModelJacobian: { x in
            model.decodeJacobian(x.expandingShape(at: 0))
              .reshaped(to: [model.imageHeight, model.imageWidth, model.imageChannels, model.latentDimension])
          },
          targetSize: targetSize))
    },
    addBetweenFactor: { (variables1, variables2, graph) -> () in
      let (poseID1, latentID1) = unpack(variables1)
      let (poseID2, latentID2) = unpack(variables2)
      graph.store(WeightedBetweenFactor(poseID1, poseID2, Pose2(), weight: 1e-2))
      graph.store(WeightedBetweenFactor(latentID1, latentID2, Vector10(), weight: 1e2))
    })
}

/// Returns a tracking configuration for a tracker using an PPCA.
///
/// Parameter model: The PPCA model to use.
/// Parameter statistics: Normalization statistics for the frames.
/// Parameter frames: The frames of the video where we want to run tracking.
/// Parameter targetSize: The size of the target in the frames.
public func makePPCATracker(
  model: PPCA,
  statistics: FrameStatistics,
  frames: [Tensor<Float>],
  targetSize: (Int, Int)
) -> TrackingConfiguration<Tuple2<Pose2, Vector10>> {
  var variableTemplate = VariableAssignments()
  var frameVariableIDs = [Tuple2<TypedID<Pose2>, TypedID<Vector10>>]()
  for _ in 0..<frames.count {
    frameVariableIDs.append(
      Tuple2(
        variableTemplate.store(Pose2()),
        variableTemplate.store(Vector10())))
  }
  return TrackingConfiguration(
    frames: frames,
    variableTemplate: variableTemplate,
    frameVariableIDs: frameVariableIDs,
    addPriorFactor: { (variables, values, graph) -> () in
      let (poseID, latentID) = unpack(variables)
      let (pose, latent) = unpack(values)
      graph.store(WeightedPriorFactor(poseID, pose, weight: 1e-2))
      graph.store(WeightedPriorFactor(latentID, latent, weight: 1e2))
    },
    addTrackingFactor: { (variables, frame, graph) -> () in
      let (poseID, latentID) = unpack(variables)
      graph.store(
        AppearanceTrackingFactor<Vector10>(
          poseID, latentID,
          measurement: statistics.normalized(frame),
          appearanceModel: { x in
            model.decode(x)
          },
          appearanceModelJacobian: { x in
            model.W // .reshaped(to: [targetSize.0, targetSize.1, frames[0].shape[3], model.latent_size])
          },
          targetSize: targetSize
        )
      )
    },
    addBetweenFactor: { (variables1, variables2, graph) -> () in
      let (poseID1, latentID1) = unpack(variables1)
      let (poseID2, latentID2) = unpack(variables2)
      graph.store(WeightedBetweenFactor(poseID1, poseID2, Pose2(), weight: 1e-2))
      graph.store(WeightedBetweenFactor(latentID1, latentID2, Vector10(), weight: 1e2))
    })
}

/// Returns a tracking configuration for a raw pixel tracker.
///
/// Parameter frames: The frames of the video where we want to run tracking.
/// Parameter target: The pixels of the target.
public func makeRawPixelTracker(
  frames: [Tensor<Float>],
  target: Tensor<Float>
) -> TrackingConfiguration<Tuple1<Pose2>> {
  var variableTemplate = VariableAssignments()
  var frameVariableIDs = [Tuple1<TypedID<Pose2>>]()
  for _ in 0..<frames.count {
    frameVariableIDs.append(
      Tuple1(
        variableTemplate.store(Pose2())))
  }
  return TrackingConfiguration(
    frames: frames,
    variableTemplate: variableTemplate,
    frameVariableIDs: frameVariableIDs,
    addPriorFactor: { (variables, values, graph) -> () in
      let poseID = variables.head
      let pose = values.head
      graph.store(WeightedPriorFactor(poseID, pose, weight: 1e0))
    },
    addTrackingFactor: { (variables, frame, graph) -> () in
      let poseID = variables.head
      graph.store(
        RawPixelTrackingFactor(poseID, measurement: frame, target: Tensor<Double>(target)))
    },
    addBetweenFactor: { (variables1, variables2, graph) -> () in
      let poseID1 = variables1.head
      let poseID2 = variables2.head
      graph.store(WeightedBetweenFactor(poseID1, poseID2, Pose2(), weight: 1e0))
    })
}

/// Returns `t` as a Swift tuple.
fileprivate func unpack<A, B>(_ t: Tuple2<A, B>) -> (A, B) {
  return (t.head, t.tail.head)
}

/// Returns `t` as a Swift tuple.
fileprivate func unpack<A>(_ t: Tuple1<A>) -> (A) {
  return (t.head)
}

/// Returns a tracking configuration for a tracker using an random projection.
///
/// Parameter model: The random projection model to use.
/// Parameter statistics: Normalization statistics for the frames.
/// Parameter frames: The frames of the video where we want to run tracking.
/// Parameter targetSize: The size of the target in the frames.
public func makeRandomProjectionTracker(
  model: RandomProjection,
  statistics: FrameStatistics,
  frames: [Tensor<Float>],
  targetSize: (Int, Int),
  foregroundModel: MultivariateGaussian,
  backgroundModel: GaussianNB
) -> TrackingConfiguration<Tuple1<Pose2>> {
  var variableTemplate = VariableAssignments()
  var frameVariableIDs = [Tuple1<TypedID<Pose2>>]()
  for _ in 0..<frames.count {
    frameVariableIDs.append(
      Tuple1(
        variableTemplate.store(Pose2())
        ))
  }

  let addPrior = { (variables: Tuple1<TypedID<Pose2>>, values: Tuple1<Pose2>, graph: inout FactorGraph) -> () in
    let (poseID) = unpack(variables)
    let (pose) = unpack(values)
    graph.store(WeightedPriorFactorPose2(poseID, pose, weight: 1e-2, rotWeight: 2e2))
  }

  let addTrackingFactor = { (variables: Tuple1<TypedID<Pose2>>, frame: Tensor<Float>, graph: inout FactorGraph) -> () in
    let (poseID) = unpack(variables)
    graph.store(
      ProbablisticTrackingFactor(poseID,
        measurement: statistics.normalized(frame),
        encoder: model,
        patchSize: targetSize,
        appearanceModelSize: targetSize,
        foregroundModel: foregroundModel,
        backgroundModel: backgroundModel,
        maxPossibleNegativity: 1e2
      )
    )
  }

  return TrackingConfiguration(
    frames: frames,
    variableTemplate: variableTemplate,
    frameVariableIDs: frameVariableIDs,
    addPriorFactor: addPrior,
    addTrackingFactor: addTrackingFactor,
    addBetweenFactor: { (variables1, variables2, graph) -> () in
      let (poseID1) = unpack(variables1)
      let (poseID2) = unpack(variables2)
      graph.store(WeightedBetweenFactorPose2(poseID1, poseID2, Pose2(), weight: 1e-2, rotWeight: 2e2))
    },
    addFixedBetweenFactor: { (values, variables, graph) -> () in
      let (prior) = unpack(values)
      let (poseID) = unpack(variables)
      graph.store(WeightedPriorFactorPose2SD(poseID, prior, sdX: 8, sdY: 4.6, sdTheta: 0.3))
    })
}

/// Get the foreground and background batches
public func getTrainingBatches(
  dataset: OISTBeeVideo, boundingBoxSize: (Int, Int),
  fgBatchSize: Int = 300, bgBatchSize: Int = 300, bgRandomFrameCount: Int = 10
) -> (fg: Tensor<Double>, bg: Tensor<Double>, statistics: FrameStatistics) {
  precondition(dataset.frames.count >= bgRandomFrameCount)
  var statistics = FrameStatistics(Tensor<Double>(0.0))
  statistics.mean = Tensor(62.26806976644069)
  statistics.standardDeviation = Tensor(37.44683834503672)

  let foregroundBatch = dataset.makeBatch(
    statistics: statistics, appearanceModelSize: boundingBoxSize,
    randomFrameCount: bgRandomFrameCount, batchSize: fgBatchSize
  )
  let backgroundBatch = dataset.makeBackgroundBatch(
    patchSize: boundingBoxSize, appearanceModelSize: boundingBoxSize,
    statistics: statistics,
    randomFrameCount: bgRandomFrameCount,
    batchSize: bgBatchSize
  )

  return (fg: foregroundBatch, bg: backgroundBatch, statistics: statistics)
}

/// Train a random projection tracker with a full Gaussian foreground model
/// and a Naive Bayes background model.
public func trainRPTracker(
  trainingData: OISTBeeVideo,
  frames: [Tensor<Float>],
  boundingBoxSize: (Int, Int), withFeatureSize d: Int,
  bgRandomFrameCount: Int = 10
) -> TrackingConfiguration<Tuple1<Pose2>> {
  let (fg, bg, statistics) = getTrainingBatches(
    dataset: trainingData, boundingBoxSize: boundingBoxSize,
    bgRandomFrameCount: bgRandomFrameCount
  )

  let randomProjector = RandomProjection(
    fromShape: [boundingBoxSize.0, boundingBoxSize.1, 1], toFeatureSize: d
  )

  var (foregroundModel, backgroundModel) = (
    MultivariateGaussian(
      dims: TensorShape([d]),
      regularizer: 1e-3
    ), GaussianNB(
      dims: TensorShape([d]),
      regularizer: 1e-3
    )
  )

  let batchPositive = randomProjector.encode(fg)
  foregroundModel.fit(batchPositive)

  let batchNegative = randomProjector.encode(bg)
  backgroundModel.fit(batchNegative)

  let tracker = makeRandomProjectionTracker(
    model: randomProjector, statistics: statistics,
    frames: frames, targetSize: boundingBoxSize,
    foregroundModel: foregroundModel, backgroundModel: backgroundModel
  )

  return tracker
}

/// Given a trained tracker, run the tracker on a given number of frames on the test set
public func createSingleTrack(
  onTrack trackId: Int,
  withTracker tracker: inout TrackingConfiguration<Tuple1<Pose2>>,
  andTestData testData: OISTBeeVideo
) -> ([Pose2], [Pose2]) {
  precondition(trackId < testData.tracks.count, "specified track does not exist!!!")

  let startPose = testData.tracks[trackId].boxes[0].center
  let prediction = tracker.infer(knownStart: Tuple1(startPose))
  let track = tracker.frameVariableIDs.map { prediction[unpack($0)] }
  let groundTruth = testData.tracks[trackId].boxes.map { $0.center }
  return (track, groundTruth)
}

/// Runs the random projections tracker
/// Given a training set, it will train an RP tracker
/// and run it on one track in the test set:
///  - output: image with track and overlap metrics
public func runRPTracker(directory: URL, onTrack trackIndex: Int, forFrames: Int = 80) -> PythonObject {
  // train foreground and background model and create tracker
  let trainingData = OISTBeeVideo(directory: directory, length: 100)!
  let testData = OISTBeeVideo(directory: directory, afterIndex: 100, length: forFrames)!
  var tracker = trainRPTracker(
    trainingData: trainingData,
    frames: testData.frames, boundingBoxSize: (40, 70), withFeatureSize: 100
  )
  
  // Run the tracker and return track with ground truth
  let (track, groundTruth) = createSingleTrack(
    onTrack: trackIndex, withTracker: &tracker,
    andTestData: testData
  )
  
  // Now create trajectory and metrics plot
  let plt = Python.import("matplotlib.pyplot")
  let (fig, axes) = plt.subplots(2, 1, figsize: Python.tuple([6, 12])).tuple2
  plotTrajectory(
    track: track, withGroundTruth: groundTruth, on: axes[0],
    withTrackColors: plt.cm.jet, withGtColors: plt.cm.gray
  )
  
  plotMetrics(
    track: track, withGroundTruth: groundTruth, on: axes[1]
  )

  return fig
}
